defmodule Firefly.Accounts.Auth.SAML.Signature do
  @moduledoc """
  Checks an enveloped XML signature (XMLDSig) on a SAML element against the
  identity provider's certificates, and nothing else: the `KeyInfo` a
  document carries is ignored, so a document signed with any other key
  fails.

  Only what SAML identity providers use is accepted, and strictly: the
  signature is a direct child of the element it signs, with exactly one
  reference, to that element's `ID`; exclusive canonicalization (see
  `Firefly.Accounts.Auth.SAML.XML`); only the enveloped-signature and
  exclusive canonicalization transforms; RSA (PKCS #1 v1.5) or ECDSA
  signatures and SHA-256/384/512 digests. SHA-1 is refused.
  """

  alias Firefly.Accounts.Auth.SAML.XML

  @ds "http://www.w3.org/2000/09/xmldsig#"
  @exc_c14n "http://www.w3.org/2001/10/xml-exc-c14n#"
  @enveloped "http://www.w3.org/2000/09/xmldsig#enveloped-signature"

  @digests %{
    "http://www.w3.org/2001/04/xmlenc#sha256" => :sha256,
    "http://www.w3.org/2001/04/xmldsig-more#sha384" => :sha384,
    "http://www.w3.org/2001/04/xmlenc#sha512" => :sha512
  }

  @signatures %{
    "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256" => {:rsa, :sha256},
    "http://www.w3.org/2001/04/xmldsig-more#rsa-sha384" => {:rsa, :sha384},
    "http://www.w3.org/2001/04/xmldsig-more#rsa-sha512" => {:rsa, :sha512},
    "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256" => {:ecdsa, :sha256},
    "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha384" => {:ecdsa, :sha384},
    "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha512" => {:ecdsa, :sha512}
  }

  @doc "Whether `element` has a signature of its own (a direct `ds:Signature` child)."
  def signed?(element), do: XML.children(element, @ds, "Signature") != []

  @doc """
  Verifies `element`'s own signature with one of `keys` (public keys, as
  `:public_key` decodes them from the certificates): `:ok` or
  `{:error, reason}`.
  """
  def verify(element, keys) do
    with {:ok, signature} <- one(XML.child(element, @ds, "Signature")),
         {:ok, signed_info} <- one(XML.child(signature, @ds, "SignedInfo")),
         {:ok, c14n_prefixes} <- canonicalization(signed_info),
         {:ok, algorithm} <- signature_method(signed_info),
         {:ok, reference} <- one(XML.child(signed_info, @ds, "Reference")),
         :ok <- check_reference(reference, element),
         {:ok, digest_prefixes} <- transforms(reference),
         :ok <- check_digest(reference, element, signature, digest_prefixes),
         {:ok, value} <- signature_value(signature, algorithm) do
      data = IO.iodata_to_binary(XML.canonicalize(signed_info, c14n_prefixes))
      {_kind, hash} = algorithm

      if Enum.any?(keys, &valid?(data, hash, value, &1)),
        do: :ok,
        else: {:error, :bad_signature}
    end
  end

  # A key of another kind than the signature's (an RSA key for an ECDSA
  # signature, say) makes `:public_key` raise rather than say no.
  defp valid?(data, hash, value, key) do
    :public_key.verify(data, hash, value, key)
  rescue
    _mismatch -> false
  end

  defp one({:ok, element}), do: {:ok, element}
  defp one(:error), do: {:error, :malformed_signature}

  defp canonicalization(signed_info) do
    with {:ok, method} <- one(XML.child(signed_info, @ds, "CanonicalizationMethod")) do
      if XML.attr(method, "Algorithm") == @exc_c14n,
        do: {:ok, inclusive_prefixes(method)},
        else: {:error, :unsupported_algorithm}
    end
  end

  defp inclusive_prefixes(method) do
    method
    |> XML.children(@exc_c14n, "InclusiveNamespaces")
    |> Enum.flat_map(&String.split(XML.attr(&1, "PrefixList") || ""))
  end

  defp signature_method(signed_info) do
    with {:ok, method} <- one(XML.child(signed_info, @ds, "SignatureMethod")) do
      case @signatures[XML.attr(method, "Algorithm")] do
        nil -> {:error, :unsupported_algorithm}
        algorithm -> {:ok, algorithm}
      end
    end
  end

  # The reference must be to the very element the signature is in: a
  # signature that points elsewhere (where an attacker moved the signed
  # content) signs nothing we read.
  defp check_reference(reference, element) do
    id = XML.attr(element, "ID")

    if is_binary(id) and id != "" and XML.attr(reference, "URI") == "#" <> id,
      do: :ok,
      else: {:error, :wrong_reference}
  end

  defp transforms(reference) do
    with {:ok, transforms} <- one(XML.child(reference, @ds, "Transforms")) do
      transforms = XML.children(transforms)
      algorithms = Enum.map(transforms, &XML.attr(&1, "Algorithm"))

      if @enveloped in algorithms and Enum.all?(algorithms, &(&1 in [@enveloped, @exc_c14n])) and
           Enum.all?(transforms, &(&1.ns == @ds and &1.local == "Transform")),
         do: {:ok, Enum.flat_map(transforms, &inclusive_prefixes/1)},
         else: {:error, :unsupported_algorithm}
    end
  end

  defp check_digest(reference, element, signature, prefixes) do
    with {:ok, method} <- one(XML.child(reference, @ds, "DigestMethod")),
         {:ok, hash} <- digest_algorithm(method),
         {:ok, value} <- one(XML.child(reference, @ds, "DigestValue")),
         {:ok, expected} <- Base.decode64(XML.text(value), ignore: :whitespace) do
      unsigned = %{element | children: Enum.reject(element.children, &(&1 === signature))}
      actual = :crypto.hash(hash, XML.canonicalize(unsigned, prefixes))
      if Plug.Crypto.secure_compare(actual, expected), do: :ok, else: {:error, :bad_digest}
    else
      :error -> {:error, :malformed_signature}
      error -> error
    end
  end

  defp digest_algorithm(method) do
    case @digests[XML.attr(method, "Algorithm")] do
      nil -> {:error, :unsupported_algorithm}
      hash -> {:ok, hash}
    end
  end

  defp signature_value(signature, {kind, _hash}) do
    with {:ok, element} <- one(XML.child(signature, @ds, "SignatureValue")),
         {:ok, value} <- Base.decode64(XML.text(element), ignore: :whitespace) do
      {:ok, if(kind == :ecdsa, do: ecdsa_der(value), else: value)}
    else
      _malformed -> {:error, :malformed_signature}
    end
  end

  # XMLDSig's ECDSA signatures are r and s side by side; `:public_key`
  # wants them DER-encoded.
  defp ecdsa_der(value) when rem(byte_size(value), 2) != 0, do: value

  defp ecdsa_der(value) do
    half = div(byte_size(value), 2)
    <<r::binary-size(^half), s::binary-size(^half)>> = value

    :public_key.der_encode(
      :"ECDSA-Sig-Value",
      {:"ECDSA-Sig-Value", :binary.decode_unsigned(r), :binary.decode_unsigned(s)}
    )
  end
end
