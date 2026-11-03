defmodule Firefly.Accounts.Auth.SAML.Response do
  @moduledoc """
  Verifies a SAML 2.0 `Response` (the HTTP-POST binding's `SAMLResponse`)
  and reads the one assertion in it.

  It's strict about shape, which is what defeats XML signature wrapping
  (signed content moved where the signature still checks out, with forged
  content where the reader looks):

    * the root is a `samlp:Response`, and no two elements share an `ID`;
    * there is exactly one `Assertion` element anywhere in the document,
      and it's a direct child of the response (encrypted assertions
      aren't supported, so are refused);
    * the response, the assertion, or both carry their own signature (see
      `Firefly.Accounts.Auth.SAML.Signature`), and each that does must
      verify against the identity provider's certificates; an unsigned
      response with an unsigned assertion is refused;
    * everything is then read from that same parsed tree, so what's read
      is what was signed.

  Then the claims: a success status; the response's and the assertion's
  issuer are the identity provider; the audience is our entity id; the
  destination and the bearer confirmation's recipient are our assertion
  consumer service; the time conditions hold (2 minutes' clock skew); and
  it answers our request (`InResponseTo`), unless it's unsolicited and
  those are allowed.
  """

  alias Firefly.Accounts.Auth.SAML.{Signature, XML}

  @protocol "urn:oasis:names:tc:SAML:2.0:protocol"
  @assertion "urn:oasis:names:tc:SAML:2.0:assertion"
  @success "urn:oasis:names:tc:SAML:2.0:status:Success"
  @bearer "urn:oasis:names:tc:SAML:2.0:cm:bearer"
  @skew 120

  @doc """
  Verifies the Base64 `saml_response` against `idp` (`entity_id`, `keys`)
  and `sp` (`entity_id`, `acs_url`). `opts`: `:now` (a `DateTime`),
  `:unsolicited` (whether a response answering no request is accepted).

  Returns `{:ok, assertion}`, with `id`, `in_response_to` (nil when
  unsolicited), `name_id`, `attributes` (each name and friendly name to
  its values) and `expires_at` (when the assertion stops being valid,
  for replay protection), or `{:error, reason}`.
  """
  def verify(saml_response, idp, sp, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, xml} <- decode(saml_response),
         {:ok, root} <- XML.parse(xml),
         {:ok, assertion} <- structure(root),
         :ok <- check_signatures(root, assertion, idp.keys),
         :ok <- check_status(root),
         :ok <- check_issuers(root, assertion, idp.entity_id),
         :ok <- check_destination(root, sp.acs_url),
         {:ok, subject} <- one(XML.child(assertion, @assertion, "Subject")),
         {:ok, in_response_to, expires_at} <- check_confirmation(subject, sp.acs_url, now),
         {:ok, conditions_expire} <- check_conditions(assertion, sp.entity_id, now),
         :ok <- check_in_response_to(root, in_response_to, opts[:unsolicited]),
         {:ok, name_id} <- one(XML.child(subject, @assertion, "NameID")) do
      {:ok,
       %{
         id: XML.attr(assertion, "ID"),
         in_response_to: in_response_to,
         name_id: XML.text(name_id),
         attributes: attributes(assertion),
         expires_at: Enum.min([expires_at, conditions_expire], DateTime)
       }}
    end
  end

  defp decode(response) when is_binary(response) do
    case Base.decode64(response, ignore: :whitespace) do
      {:ok, xml} -> {:ok, xml}
      :error -> {:error, :invalid_xml}
    end
  end

  defp decode(_response), do: {:error, :invalid_xml}

  defp one({:ok, element}), do: {:ok, element}
  defp one(:error), do: {:error, :malformed_response}

  defp structure(%{ns: @protocol, local: "Response"} = root) do
    elements = XML.elements(root)
    ids = for element <- elements, id = XML.attr(element, "ID"), do: id
    assertions = Enum.filter(elements, &(&1.ns == @assertion and &1.local == "Assertion"))

    cond do
      length(ids) != length(Enum.uniq(ids)) -> {:error, :duplicate_ids}
      Enum.any?(elements, &(&1.local == "EncryptedAssertion")) -> {:error, :encrypted_assertion}
      length(assertions) != 1 -> {:error, :wrapped_assertion}
      XML.children(root, @assertion, "Assertion") != assertions -> {:error, :wrapped_assertion}
      XML.attr(hd(assertions), "ID") in [nil, ""] -> {:error, :malformed_response}
      true -> {:ok, hd(assertions)}
    end
  end

  defp structure(_root), do: {:error, :not_a_response}

  defp check_signatures(root, assertion, keys) do
    signed = Enum.filter([root, assertion], &Signature.signed?/1)

    if signed == [],
      do: {:error, :unsigned},
      else: Enum.find_value(signed, :ok, &signature_error(&1, keys))
  end

  defp signature_error(element, keys) do
    case Signature.verify(element, keys) do
      :ok -> nil
      error -> error
    end
  end

  defp check_status(root) do
    with {:ok, status} <- one(XML.child(root, @protocol, "Status")),
         {:ok, code} <- one(XML.child(status, @protocol, "StatusCode")) do
      case XML.attr(code, "Value") do
        @success -> :ok
        _failure -> {:error, :login_failed}
      end
    end
  end

  # The response's issuer is optional; the assertion's isn't.
  defp check_issuers(root, assertion, entity_id) do
    response_issuer = XML.children(root, @assertion, "Issuer")

    with {:ok, issuer} <- one(XML.child(assertion, @assertion, "Issuer")) do
      if Enum.all?([issuer | response_issuer], &(XML.text(&1) == entity_id)),
        do: :ok,
        else: {:error, :wrong_issuer}
    end
  end

  defp check_destination(root, acs_url) do
    if XML.attr(root, "Destination") in [nil, acs_url], do: :ok, else: {:error, :wrong_recipient}
  end

  # A bearer confirmation for us, still valid: its request and expiry.
  defp check_confirmation(subject, acs_url, now) do
    confirmation =
      subject
      |> XML.children(@assertion, "SubjectConfirmation")
      |> Enum.filter(&(XML.attr(&1, "Method") == @bearer))
      |> Enum.flat_map(&XML.children(&1, @assertion, "SubjectConfirmationData"))
      |> Enum.find(&(XML.attr(&1, "Recipient") == acs_url))

    with {:ok, confirmation} <- found(confirmation, :wrong_recipient),
         {:ok, not_on_or_after} <- time(confirmation, "NotOnOrAfter"),
         {:ok, not_on_or_after} <- found(not_on_or_after, :malformed_response),
         :ok <- check_window(nil, not_on_or_after, now) do
      {:ok, XML.attr(confirmation, "InResponseTo"), not_on_or_after}
    end
  end

  defp found(nil, reason), do: {:error, reason}
  defp found(value, _reason), do: {:ok, value}

  defp check_conditions(assertion, sp_entity_id, now) do
    with {:ok, conditions} <- one(XML.child(assertion, @assertion, "Conditions")),
         {:ok, not_before} <- time(conditions, "NotBefore"),
         {:ok, not_on_or_after} <- time(conditions, "NotOnOrAfter"),
         :ok <- check_window(not_before, not_on_or_after, now),
         :ok <- check_audience(conditions, sp_entity_id) do
      {:ok, not_on_or_after || DateTime.add(now, 300)}
    end
  end

  # Every audience restriction must name us.
  defp check_audience(conditions, sp_entity_id) do
    restrictions = XML.children(conditions, @assertion, "AudienceRestriction")

    if restrictions != [] and
         Enum.all?(restrictions, fn restriction ->
           restriction
           |> XML.children(@assertion, "Audience")
           |> Enum.any?(&(XML.text(&1) == sp_entity_id))
         end),
       do: :ok,
       else: {:error, :wrong_audience}
  end

  defp time(element, attribute) do
    case XML.attr(element, attribute) do
      nil ->
        {:ok, nil}

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, time, _offset} -> {:ok, time}
          _invalid -> {:error, :malformed_response}
        end
    end
  end

  defp check_window(not_before, not_on_or_after, now) do
    cond do
      not_before && DateTime.diff(not_before, now) > @skew -> {:error, :expired}
      not_on_or_after && DateTime.diff(now, not_on_or_after) >= @skew -> {:error, :expired}
      true -> :ok
    end
  end

  # The response and its confirmation answer the same request, or (when
  # allowed) none.
  defp check_in_response_to(root, in_response_to, unsolicited?) do
    response_to = XML.attr(root, "InResponseTo")

    cond do
      response_to != nil and response_to != in_response_to -> {:error, :wrong_request}
      in_response_to == nil and unsolicited? != true -> {:error, :unsolicited}
      true -> :ok
    end
  end

  defp attributes(assertion) do
    for statement <- XML.children(assertion, @assertion, "AttributeStatement"),
        attribute <- XML.children(statement, @assertion, "Attribute"),
        name <-
          Enum.reject(
            [XML.attr(attribute, "Name"), XML.attr(attribute, "FriendlyName")],
            &is_nil/1
          ),
        reduce: %{} do
      acc ->
        values = attribute |> XML.children(@assertion, "AttributeValue") |> Enum.map(&XML.text/1)
        Map.update(acc, name, values, &(&1 ++ values))
    end
  end
end
