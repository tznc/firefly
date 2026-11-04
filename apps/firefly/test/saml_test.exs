defmodule Firefly.SAMLTest do
  use Firefly.DataCase, async: true

  import Firefly.Fixtures

  alias Firefly.{Repo, SAMLTestIdP}
  alias Firefly.Accounts.Auth.SAML
  alias Firefly.Accounts.Auth.SAML.{Metadata, Response, XML}
  alias Firefly.Accounts.UserIdentity
  alias Firefly.Groups

  @dir SAMLTestIdP.dir()
  @fixture_sp %{
    entity_id: "https://forum.example.com/saml/metadata",
    acs_url: "https://forum.example.com/auth/saml/acs"
  }
  @fixture_now ~U[2026-11-03 12:01:00Z]

  defp idp(cert \\ "idp") do
    keys = cert |> SAMLTestIdP.certificate() |> Metadata.certificates_from_pem()
    %{entity_id: SAMLTestIdP.entity_id(), keys: Enum.map(keys, &Metadata.public_key/1)}
  end

  defp fixture(name), do: File.read!(Path.join(@dir, "#{name}.xml"))

  defp verify_fixture(xml, opts \\ []) do
    Response.verify(
      Base.encode64(xml),
      Keyword.get(opts, :idp, idp()),
      Keyword.get(opts, :sp, @fixture_sp),
      Keyword.merge([now: @fixture_now], opts)
    )
  end

  describe "responses signed by real-world-shaped identity providers" do
    test "an Okta-style response with a signed assertion and inclusive namespaces" do
      assert {:ok, assertion} = verify_fixture(fixture("okta"))
      assert assertion.name_id == "00u1okta"
      assert assertion.in_response_to == "_req_fixture"
      assert assertion.attributes["email"] == ["ada@example.com"]
      assert assertion.attributes["displayName"] == ["Ada & Lovelace"]
      assert assertion.attributes["groups"] == ["engineers", "everyone"]
      assert assertion.expires_at == ~U[2026-11-03 12:05:00Z]
    end

    test "an Azure-style signed response with default namespaces" do
      assert {:ok, %{name_id: "azure-object-id", attributes: attributes}} =
               verify_fixture(fixture("azure"))

      assert attributes["http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"] ==
               ["grace@example.com"]
    end

    test "a Keycloak-style response, both signed with SHA-512, namespaces inherited" do
      assert {:ok, %{name_id: "f3b1c2d4-kc", attributes: %{"email" => ["linus@example.com"]}}} =
               verify_fixture(fixture("keycloak"))
    end

    test "an ECDSA signature" do
      key = :public_key.generate_key({:namedCurve, :secp256r1})
      {:ECPrivateKey, _, _, params, public, _} = key
      SAMLTestIdP.setup()
      xml = SAMLTestIdP.response_xml([key: key], "_req")

      idp = %{entity_id: SAMLTestIdP.entity_id(), keys: [{{:ECPoint, public}, params}]}

      assert {:ok, _} = Response.verify(Base.encode64(xml), idp, SAML.service_provider())
    end
  end

  describe "refused responses" do
    test "signed with another key" do
      assert {:error, :bad_signature} = verify_fixture(fixture("okta"), idp: idp("other"))
    end

    test "changed after signing" do
      xml = String.replace(fixture("okta"), "ada@example.com", "admin@example.com")
      assert {:error, :bad_digest} = verify_fixture(xml)

      # Even in a way canonicalization ignores nothing of: whitespace.
      xml = String.replace(fixture("okta"), "<saml2:Issuer>", "<saml2:Issuer> ")
      assert {:error, :bad_digest} = verify_fixture(xml)
    end

    test "unsigned" do
      xml = Regex.replace(~r{<ds:Signature.*</ds:Signature>}s, fixture("okta"), "")
      assert {:error, :unsigned} = verify_fixture(xml)
    end

    test "a response signature that doesn't verify isn't saved by a valid assertion one" do
      xml = String.replace(fixture("keycloak"), "Destination=", "Consent=\"x\" Destination=")
      assert {:error, :bad_digest} = verify_fixture(xml)
    end

    test "wrapped: a forged assertion where the signed one was, the signed one hidden" do
      xml = fixture("okta")
      [signed] = Regex.run(~r{<saml2:Assertion .*</saml2:Assertion>}s, xml)

      forged =
        signed
        |> String.replace("id-okta-assertion", "id-forged")
        |> String.replace("00u1okta", "00u1admin")
        |> then(&Regex.replace(~r{<ds:Signature.*</ds:Signature>}s, &1, ""))

      # The signed assertion tucked into the status, or the forged one beside it.
      hidden =
        String.replace(
          xml,
          signed,
          forged <> "<saml2p:Extensions>#{signed}</saml2p:Extensions>"
        )

      assert {:error, :wrapped_assertion} = verify_fixture(hidden)

      assert {:error, :wrapped_assertion} =
               verify_fixture(String.replace(xml, signed, forged <> signed))
    end

    test "wrapped: the signature copied onto a forged assertion with the same id" do
      xml = fixture("okta")
      [signed] = Regex.run(~r{<saml2:Assertion .*</saml2:Assertion>}s, xml)
      forged = String.replace(signed, "00u1okta", "00u1admin")

      assert {:error, :bad_digest} = verify_fixture(String.replace(xml, signed, forged))

      # Two elements with the signed id: refused before looking any further.
      both = String.replace(xml, signed, forged <> "<x:Keep xmlns:x=\"urn:x\">#{signed}</x:Keep>")
      assert {:error, :duplicate_ids} = verify_fixture(both)
    end

    test "a signature over another element than the one it's in" do
      xml =
        String.replace(fixture("okta"), ~s{URI="#id-okta-assertion"}, ~s{URI="#id-okta-response"})

      assert {:error, :wrong_reference} = verify_fixture(xml)
    end

    test "SHA-1 and unknown transforms" do
      sha1 =
        String.replace(
          fixture("okta"),
          "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256",
          "http://www.w3.org/2000/09/xmldsig#rsa-sha1"
        )

      assert {:error, :unsupported_algorithm} = verify_fixture(sha1)

      xslt =
        String.replace(
          fixture("okta"),
          "http://www.w3.org/2000/09/xmldsig#enveloped-signature",
          "http://www.w3.org/TR/1999/REC-xslt-19991116"
        )

      assert {:error, :unsupported_algorithm} = verify_fixture(xslt)
    end

    test "external entities (XXE) and DTDs" do
      xxe =
        String.replace(
          fixture("okta"),
          "<saml2p:Response",
          ~s{<!DOCTYPE r [<!ENTITY e SYSTEM "file:///etc/passwd">]><saml2p:Response},
          global: false
        )

      assert {:error, :invalid_xml} = verify_fixture(xxe)
      assert {:error, :invalid_xml} = verify_fixture("not xml")
      assert {:error, :invalid_xml} = Response.verify("%%%", idp(), @fixture_sp)
    end

    test "encrypted assertions" do
      xml =
        String.replace(
          fixture("azure"),
          "<samlp:Status>",
          ~s{<EncryptedAssertion xmlns="urn:oasis:names:tc:SAML:2.0:assertion"/><samlp:Status>}
        )

      assert {:error, :encrypted_assertion} = verify_fixture(xml)
    end

    test "expired, not yet valid, or for someone else" do
      assert {:error, :expired} = verify_fixture(fixture("okta"), now: ~U[2026-11-03 12:08:00Z])
      assert {:error, :expired} = verify_fixture(fixture("okta"), now: ~U[2026-11-03 11:50:00Z])
      # Within the clock skew allowed.
      assert {:ok, _} = verify_fixture(fixture("okta"), now: ~U[2026-11-03 12:06:00Z])

      assert {:error, :wrong_audience} =
               verify_fixture(fixture("okta"), sp: %{@fixture_sp | entity_id: "https://other"})

      assert {:error, :wrong_recipient} =
               verify_fixture(fixture("okta"), sp: %{@fixture_sp | acs_url: "https://other/acs"})

      assert {:error, :wrong_issuer} =
               verify_fixture(fixture("okta"), idp: %{idp() | entity_id: "https://evil"})
    end

    test "unsolicited, unless allowed" do
      SAMLTestIdP.setup()
      response = SAMLTestIdP.response(nil)
      sp = SAML.service_provider()

      assert {:error, :unsolicited} = Response.verify(response, idp(), sp)

      assert {:ok, %{in_response_to: nil}} =
               Response.verify(response, idp(), sp, unsolicited: true)
    end

    test "comments can't truncate what's read: it's what was signed" do
      SAMLTestIdP.setup()

      response =
        SAMLTestIdP.response("_req",
          name_id_xml: "<saml:NameID>admin@example.com<!-- x -->.evil.example</saml:NameID>"
        )

      assert {:ok, %{name_id: "admin@example.com.evil.example"}} =
               Response.verify(response, idp(), SAML.service_provider())
    end
  end

  describe "canonicalization" do
    test "renders only the namespaces used, sorted, with attributes in order" do
      {:ok, root} =
        XML.parse(
          ~s{<a:r xmlns:a="urn:a" xmlns:b="urn:b" xmlns:unused="urn:u"><b:c z="1" b:y="2" a="&lt;&quot;&#10;">t &amp; &gt;</b:c><d xmlns="urn:d"><e/></d></a:r>}
        )

      [child | _] = XML.children(root)

      assert IO.iodata_to_binary(XML.canonicalize(child)) ==
               ~s{<b:c xmlns:b="urn:b" a="&lt;&quot;&#xA;" z="1" b:y="2">t &amp; &gt;</b:c>}

      assert IO.iodata_to_binary(XML.canonicalize(root, ["unused"])) ==
               ~s{<a:r xmlns:a="urn:a" xmlns:unused="urn:u"><b:c xmlns:b="urn:b" a="&lt;&quot;&#xA;" z="1" b:y="2">t &amp; &gt;</b:c><d xmlns="urn:d"><e></e></d></a:r>}
    end

    test "refuses undeclared prefixes" do
      assert {:error, :invalid_xml} = XML.parse("<x:a/>")
    end
  end

  describe "metadata" do
    test "reads the identity provider's" do
      assert {:ok, idp} = Metadata.parse_idp(fixture("idp_metadata"))
      assert idp.entity_id == "https://idp.example.com/saml"
      assert idp.sso_url == "https://idp.example.com/saml/sso"
      assert idp.certificates == Metadata.certificates_from_pem(SAMLTestIdP.certificate())
      assert {:error, :invalid_metadata} = Metadata.parse_idp("<nope/>")
    end

    test "configured from pasted metadata, the settings overriding it" do
      SAMLTestIdP.setup(%{
        "saml_idp_sso_url" => "",
        "saml_idp_certificate" => "",
        "saml_idp_metadata_xml" => fixture("idp_metadata")
      })

      assert SAML.enabled?()

      assert {:ok, %{sso_url: "https://idp.example.com/saml/sso", keys: [_]}} =
               SAML.identity_provider()

      SAMLTestIdP.setup(%{"saml_idp_sso_url" => "https://login.example.com/x"})
      assert {:ok, %{sso_url: "https://login.example.com/x"}} = SAML.identity_provider()
    end

    test "ours names our entity id, consumer service and (when signing) certificate" do
      SAMLTestIdP.setup()
      sp = SAML.service_provider()
      metadata = SAML.metadata()

      assert metadata =~ ~s{entityID="#{sp.entity_id}"}
      assert metadata =~ ~s{Location="#{sp.acs_url}"}
      assert metadata =~ ~s{AuthnRequestsSigned="false"}
      assert {:ok, _} = XML.parse(metadata)
    end
  end

  describe "logins" do
    setup do
      SAMLTestIdP.setup()
    end

    defp request_id(url) do
      %{"SAMLRequest" => request} = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      xml = request |> Base.decode64!() |> :zlib.unzip()
      [_, id] = Regex.run(~r/ ID="([^"]+)"/, xml)
      {id, xml}
    end

    test "a request, its answer, and the answer handed over once" do
      assert {:ok, id, url} = SAML.request("/latest")
      assert String.starts_with?(url, SAMLTestIdP.sso_url() <> "?")
      assert {^id, xml} = request_id(url)
      assert xml =~ ~s{AssertionConsumerServiceURL="#{SAML.service_provider().acs_url}"}
      assert URI.decode_query(URI.parse(url).query)["RelayState"] == "/latest"

      response = SAMLTestIdP.response(id, attributes: %{"email" => ["ada@example.com"]})
      assert {:ok, :solicited} = SAML.consume(response, "/latest")

      assert {:ok, %{return_to: "/latest", result: result}} = SAML.take(id)
      assert result["name_id"] == "idp-user-1"
      assert {:error, :expired} = SAML.take(id)
    end

    test "each assertion and each request is used once" do
      {:ok, id, _url} = SAML.request("/")
      response = SAMLTestIdP.response(id)
      assert {:ok, :solicited} = SAML.consume(response, nil)
      assert {:error, :replayed} = SAML.consume(response, nil)
      assert {:error, :unknown_request} = SAML.consume(SAMLTestIdP.response(id), nil)
      assert {:error, :unknown_request} = SAML.consume(SAMLTestIdP.response("_made_up"), nil)
    end

    test "unsolicited answers get a ticket only when allowed" do
      assert {:error, :unsolicited} = SAML.consume(SAMLTestIdP.response(nil), "/x")

      SAMLTestIdP.setup(%{"saml_idp_initiated" => "true"})
      assert {:ok, {:unsolicited, ticket}} = SAML.consume(SAMLTestIdP.response(nil), "/x")
      assert {:ok, %{return_to: "/x"}} = SAML.take(ticket)
    end

    test "nothing is accepted while SAML is off" do
      {:ok, id, _url} = SAML.request("/")
      SAMLTestIdP.setup(%{"saml_enabled" => "false"})
      assert {:error, :not_configured} = SAML.consume(SAMLTestIdP.response(id), nil)
    end

    test "signed requests, with the configured key" do
      original = Application.get_env(:firefly, SAML)
      on_exit(fn -> Application.put_env(:firefly, SAML, original || []) end)

      Application.put_env(:firefly, SAML,
        sp_key: File.read!(Path.join(@dir, "other_key.pem")),
        sp_cert: SAMLTestIdP.certificate("other")
      )

      SAMLTestIdP.setup(%{"saml_sign_requests" => "true"})
      {:ok, _id, url} = SAML.request("/")
      query = URI.parse(url).query
      [signed, signature] = String.split(query, "&Signature=")
      assert signed =~ "&SigAlg="

      [der] = Metadata.certificates_from_pem(SAMLTestIdP.certificate("other"))

      assert :public_key.verify(
               signed,
               :sha256,
               Base.decode64!(URI.decode_www_form(signature)),
               Metadata.public_key(der)
             )

      assert SAML.metadata() =~ ~s{AuthnRequestsSigned="true"}
    end

    test "attribute mapping, account linking and group sync" do
      {:ok, _engineers} = Groups.create_role("engineers")
      {:ok, old} = Groups.create_role("old-team")
      SAMLTestIdP.setup(%{"saml_groups_attributes" => "memberOf"})

      result = %{
        "name_id" => "idp-user-9",
        "attributes" => %{
          "mail" => ["grace@example.com"],
          "uid" => ["grace"],
          "displayName" => ["Grace Hopper"],
          "memberOf" => ["engineers", "nonexistent", "admin"]
        }
      }

      assert {:ok, user} = SAML.login(result)

      assert {user.username, user.email, user.name} ==
               {"grace", "grace@example.com", "Grace Hopper"}

      assert user.confirmed_at
      assert Repo.get_by(UserIdentity, provider: "saml", uid: "idp-user-9").user_id == user.id

      roles = fn ->
        user |> Repo.preload(:roles, force: true) |> Map.get(:roles) |> Enum.map(& &1.name)
      end

      assert roles.() == ["engineers"]

      {:ok, _} = Groups.add_role(user, old)

      assert {:ok, again} =
               SAML.login(%{
                 result
                 | "attributes" => Map.delete(result["attributes"], "memberOf")
               })

      assert again.id == user.id
      assert roles.() == []
    end

    test "the account id can come from an attribute" do
      SAMLTestIdP.setup(%{"saml_uid_attribute" => "employeeNumber"})

      info =
        SAML.info(%{"name_id" => "transient-1", "attributes" => %{"employeeNumber" => ["42"]}})

      assert info.uid == "42"
    end

    test "registration rules still apply" do
      {:ok, _} =
        Firefly.SiteSettings.update(%{"allow_registrations" => "false"}, admin_fixture())

      assert {:error, "New registrations are closed."} =
               SAML.login(%{"name_id" => "new", "attributes" => %{}})
    end
  end
end
