defmodule Firefly.SAMLTestIdP do
  @moduledoc """
  A SAML identity provider for tests: it configures the site to trust it
  (`setup/1`) and makes signed responses (`response/1`) the way real ones
  look, signed with the test key in `test/fixtures/saml` (or another).
  Signing uses our own canonicalization: the fixtures there signed by
  libxml2 check that one against a reference implementation.
  """

  # Test support, for any app's tests: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]

  alias Firefly.{Repo, SiteSettings}
  alias Firefly.Accounts.Auth.SAML
  alias Firefly.Accounts.Auth.SAML.XML
  alias Firefly.SiteSettings.SiteSetting

  @dir Path.expand("../fixtures/saml", __DIR__)
  @entity_id "https://idp.example.com/saml"
  @sso_url "https://idp.example.com/saml/sso"
  @ds "http://www.w3.org/2000/09/xmldsig#"

  def dir, do: @dir
  def entity_id, do: @entity_id
  def sso_url, do: @sso_url

  @doc "The test IdP's certificate (PEM), or another one (`\"other\"`)."
  def certificate(name \\ "idp"), do: File.read!(Path.join(@dir, "#{name}_cert.pem"))

  @doc "A private key in `test/fixtures/saml` (`\"idp\"` or `\"other\"`)."
  def key(name \\ "idp") do
    [entry] = :public_key.pem_decode(File.read!(Path.join(@dir, "#{name}_key.pem")))
    :public_key.pem_entry_decode(entry)
  end

  @doc "Turns SAML logins on with this identity provider, plus `settings`."
  def setup(settings \\ %{}) do
    %{
      "saml_enabled" => "true",
      "saml_name" => "Corp SAML",
      "saml_idp_entity_id" => @entity_id,
      "saml_idp_sso_url" => @sso_url,
      "saml_idp_certificate" => certificate()
    }
    |> Map.merge(settings)
    |> Enum.each(fn {key, value} ->
      Repo.insert!(%SiteSetting{key: key, value: value},
        on_conflict: [set: [value: value]],
        conflict_target: :key
      )
    end)

    SiteSettings.clear_cache()
  end

  @doc """
  A Base64 `SAMLResponse` answering `in_response_to` (nil: unsolicited).
  `opts`: `:name_id`, `:attributes` (name to values), `:issuer`,
  `:audience`, `:recipient`, `:not_on_or_after`, `:assertion_id`,
  `:key` (to sign with), `:sign` (`:assertion` by default, `:response`,
  `:both` or `:none`), `:name_id_xml` (raw).
  """
  def response(in_response_to, opts \\ []) do
    opts |> response_xml(in_response_to) |> Base.encode64()
  end

  @doc "The response's XML, as `response/2` makes it."
  def response_xml(opts, in_response_to) do
    sp = SAML.service_provider()
    now = DateTime.utc_now(:second)
    expires = opts[:not_on_or_after] || DateTime.add(now, 300)
    key = opts[:key] || key()
    sign = opts[:sign] || :assertion
    assertion_id = opts[:assertion_id] || "_a#{System.unique_integer([:positive])}"
    response_id = "_r#{System.unique_integer([:positive])}"
    issuer = opts[:issuer] || @entity_id
    in_response = if in_response_to, do: ~s{ InResponseTo="#{in_response_to}"}, else: ""

    attributes =
      for {name, values} <- opts[:attributes] || %{} do
        ~s{<saml:Attribute Name="#{name}">} <>
          Enum.map_join(values, &"<saml:AttributeValue>#{&1}</saml:AttributeValue>") <>
          "</saml:Attribute>"
      end

    assertion =
      ~s{<saml:Assertion xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" ID="#{assertion_id}" } <>
        ~s{IssueInstant="#{DateTime.to_iso8601(now)}" Version="2.0">} <>
        ~s{<saml:Issuer>#{issuer}</saml:Issuer>} <>
        ~s{<saml:Subject>} <>
        (opts[:name_id_xml] || ~s{<saml:NameID>#{opts[:name_id] || "idp-user-1"}</saml:NameID>}) <>
        ~s{<saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">} <>
        ~s{<saml:SubjectConfirmationData#{in_response} NotOnOrAfter="#{DateTime.to_iso8601(expires)}" } <>
        ~s{Recipient="#{opts[:recipient] || sp.acs_url}"/></saml:SubjectConfirmation></saml:Subject>} <>
        ~s{<saml:Conditions NotBefore="#{DateTime.to_iso8601(DateTime.add(now, -60))}" } <>
        ~s{NotOnOrAfter="#{DateTime.to_iso8601(expires)}"><saml:AudienceRestriction>} <>
        ~s{<saml:Audience>#{opts[:audience] || sp.entity_id}</saml:Audience>} <>
        ~s{</saml:AudienceRestriction></saml:Conditions>} <>
        ~s{<saml:AttributeStatement>#{attributes}</saml:AttributeStatement></saml:Assertion>}

    assertion = if sign in [:assertion, :both], do: sign(assertion, key), else: assertion

    response =
      ~s{<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ID="#{response_id}" } <>
        ~s{Version="2.0" IssueInstant="#{DateTime.to_iso8601(now)}" Destination="#{sp.acs_url}"#{in_response}>} <>
        ~s{<saml:Issuer xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">#{issuer}</saml:Issuer>} <>
        ~s{<samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>} <>
        assertion <> "</samlp:Response>"

    if sign in [:response, :both], do: sign(response, key), else: response
  end

  @doc """
  Signs the root element of `xml` (it must declare every namespace it
  uses), inserting the signature after its `Issuer`.
  """
  def sign(xml, key) do
    {:ok, element} = XML.parse(xml)
    id = XML.attr(element, "ID")
    digest = Base.encode64(:crypto.hash(:sha256, XML.canonicalize(element)))

    signed_info =
      ~s{<ds:SignedInfo xmlns:ds="#{@ds}"><ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>} <>
        ~s{<ds:SignatureMethod Algorithm="#{signature_algorithm(key)}"/>} <>
        ~s{<ds:Reference URI="##{id}"><ds:Transforms>} <>
        ~s{<ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>} <>
        ~s{<ds:Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/></ds:Transforms>} <>
        ~s{<ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/>} <>
        ~s{<ds:DigestValue>#{digest}</ds:DigestValue></ds:Reference></ds:SignedInfo>}

    {:ok, info} = XML.parse(signed_info)

    value =
      info |> XML.canonicalize() |> IO.iodata_to_binary() |> sign_data(key) |> Base.encode64()

    signature =
      ~s{<ds:Signature xmlns:ds="#{@ds}">} <>
        String.replace(signed_info, ~s{ xmlns:ds="#{@ds}"}, "") <>
        ~s{<ds:SignatureValue>#{value}</ds:SignatureValue></ds:Signature>}

    [head, tail] = String.split(xml, "</saml:Issuer>", parts: 2)
    head <> "</saml:Issuer>" <> signature <> tail
  end

  # XMLDSig's ECDSA signatures are r and s side by side, not DER.
  defp sign_data(data, key) when elem(key, 0) == :ECPrivateKey do
    {:"ECDSA-Sig-Value", r, s} =
      :public_key.der_decode(:"ECDSA-Sig-Value", :public_key.sign(data, :sha256, key))

    <<r::unsigned-big-256, s::unsigned-big-256>>
  end

  defp sign_data(data, key), do: :public_key.sign(data, :sha256, key)

  defp signature_algorithm(key) when elem(key, 0) == :ECPrivateKey,
    do: "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256"

  defp signature_algorithm(_rsa), do: "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
end
