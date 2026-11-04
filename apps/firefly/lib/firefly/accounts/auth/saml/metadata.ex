defmodule Firefly.Accounts.Auth.SAML.Metadata do
  @moduledoc """
  SAML metadata: reading an identity provider's (its entity id, single
  sign-on URL and signing certificates) and writing ours, the service
  provider's, for the identity provider to import.
  """

  require Record

  alias Firefly.Accounts.Auth.SAML.XML

  Record.defrecordp(
    :certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  @md "urn:oasis:names:tc:SAML:2.0:metadata"
  @ds "http://www.w3.org/2000/09/xmldsig#"
  @redirect "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
  @post "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"

  @doc """
  The identity provider in metadata `xml` (an `EntityDescriptor`, or the
  first with an `IDPSSODescriptor` in an `EntitiesDescriptor`):
  `{:ok, %{entity_id, sso_url, certificates}}` (`sso_url` is its
  HTTP-Redirect single sign-on service; `certificates` are DER, those for
  signing) or `{:error, :invalid_metadata}`.
  """
  def parse_idp(xml) do
    with {:ok, root} <- XML.parse(xml),
         %{} = entity <- idp_entity(root),
         {:ok, descriptor} <- XML.child(entity, @md, "IDPSSODescriptor") do
      {:ok,
       %{
         entity_id: XML.attr(entity, "entityID"),
         sso_url: sso_url(descriptor),
         certificates: signing_certificates(descriptor)
       }}
    else
      _invalid -> {:error, :invalid_metadata}
    end
  end

  defp idp_entity(%{ns: @md, local: "EntityDescriptor"} = entity), do: entity

  defp idp_entity(%{ns: @md, local: "EntitiesDescriptor"} = root) do
    root
    |> XML.children(@md, "EntityDescriptor")
    |> Enum.find(&(XML.children(&1, @md, "IDPSSODescriptor") != []))
  end

  defp idp_entity(_root), do: nil

  defp sso_url(descriptor) do
    descriptor
    |> XML.children(@md, "SingleSignOnService")
    |> Enum.find_value(&if(XML.attr(&1, "Binding") == @redirect, do: XML.attr(&1, "Location")))
  end

  # Keys without a `use` are for signing too.
  defp signing_certificates(descriptor) do
    for key <- XML.children(descriptor, @md, "KeyDescriptor"),
        XML.attr(key, "use") in [nil, "signing"],
        {:ok, info} <- [XML.child(key, @ds, "KeyInfo")],
        data <- XML.children(info, @ds, "X509Data"),
        cert <- XML.children(data, @ds, "X509Certificate"),
        {:ok, der} <- [Base.decode64(XML.text(cert), ignore: :whitespace)],
        do: der
  end

  @doc """
  The certificates (DER) in `pem`: PEM blocks, or bare Base64 as
  metadata has them.
  """
  def certificates_from_pem(pem) when is_binary(pem) do
    case :public_key.pem_decode(pem) do
      [] ->
        case Base.decode64(pem, ignore: :whitespace) do
          {:ok, der} -> [der]
          :error -> []
        end

      entries ->
        for {:Certificate, der, :not_encrypted} <- entries, do: der
    end
  end

  def certificates_from_pem(_pem), do: []

  @doc "The public key in the DER certificate `der`, for `:public_key.verify/4`; nil if unreadable."
  def public_key(der) do
    cert = :public_key.pkix_decode_cert(der, :otp)
    info = cert |> certificate(:tbsCertificate) |> tbs(:subjectPublicKeyInfo)
    {:PublicKeyAlgorithm, _oid, params} = key_info(info, :algorithm)

    case key_info(info, :subjectPublicKey) do
      {:ECPoint, _point} = point -> {point, params}
      key -> key
    end
  rescue
    _unreadable -> nil
  catch
    _kind, _reason -> nil
  end

  @doc """
  Our metadata: `entity_id`, `acs_url`, and when requests are signed, the
  signing `certificate` (DER).
  """
  def service_provider(entity_id, acs_url, certificate) do
    key_descriptor =
      if certificate do
        ~s{<md:KeyDescriptor use="signing"><ds:KeyInfo xmlns:ds="#{@ds}"><ds:X509Data><ds:X509Certificate>} <>
          Base.encode64(certificate) <>
          ~s{</ds:X509Certificate></ds:X509Data></ds:KeyInfo></md:KeyDescriptor>}
      else
        ""
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <md:EntityDescriptor xmlns:md="#{@md}" entityID="#{escape(entity_id)}">\
    <md:SPSSODescriptor AuthnRequestsSigned="#{certificate != nil}" WantAssertionsSigned="true" \
    protocolSupportEnumeration="urn:oasis:names:tc:SAML:2.0:protocol">#{key_descriptor}\
    <md:NameIDFormat>urn:oasis:names:tc:SAML:2.0:nameid-format:persistent</md:NameIDFormat>\
    <md:AssertionConsumerService Binding="#{@post}" Location="#{escape(acs_url)}" index="0" isDefault="true"/>\
    </md:SPSSODescriptor></md:EntityDescriptor>
    """
  end

  @doc "`text` escaped for an XML attribute or text."
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
