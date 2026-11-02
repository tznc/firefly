defmodule FirestormWeb.Uploads.AWS.SigV4Test do
  use ExUnit.Case, async: true

  alias FirestormWeb.Uploads.AWS.SigV4
  alias FirestormWeb.Uploads.Storage.S3

  @now ~U[2026-11-01 12:34:56Z]
  @key "original/ab/abcdef.png"

  # Independently derived signing key, per the AWS SigV4 spec.
  defp signing_key do
    "AWS4test-secret-access-key"
    |> mac("20261101")
    |> mac("us-east-1")
    |> mac("s3")
    |> mac("aws4_request")
  end

  defp mac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(data), do: Base.encode16(data, case: :lower)

  test "signs requests with an Authorization header over the payload" do
    {url, headers} = SigV4.request("PUT", @key, "data", [{"content-type", "image/png"}], @now)
    headers = Map.new(headers)

    assert url == "https://firestorm-test.s3.us-east-1.amazonaws.com/" <> @key
    assert headers["x-amz-content-sha256"] == hex(:crypto.hash(:sha256, "data"))
    assert headers["x-amz-date"] == "20261101T123456Z"

    canonical =
      Enum.join(
        [
          "PUT",
          "/" <> @key,
          "",
          "content-type:image/png\nhost:firestorm-test.s3.us-east-1.amazonaws.com\n" <>
            "x-amz-content-sha256:#{headers["x-amz-content-sha256"]}\nx-amz-date:20261101T123456Z\n",
          "content-type;host;x-amz-content-sha256;x-amz-date",
          headers["x-amz-content-sha256"]
        ],
        "\n"
      )

    to_sign =
      "AWS4-HMAC-SHA256\n20261101T123456Z\n20261101/us-east-1/s3/aws4_request\n" <>
        hex(:crypto.hash(:sha256, canonical))

    assert headers["authorization"] ==
             "AWS4-HMAC-SHA256 Credential=test-access-key-id/20261101/us-east-1/s3/aws4_request, " <>
               "SignedHeaders=content-type;host;x-amz-content-sha256;x-amz-date, " <>
               "Signature=#{hex(mac(signing_key(), to_sign))}"
  end

  test "presigns GET links that expire, with the response headers to send" do
    url =
      SigV4.presigned_url(
        @key,
        300,
        %{"response-content-disposition" => ~s(inline; filename="a.png")},
        @now
      )

    %URI{host: host, path: path, query: query} = URI.parse(url)
    params = URI.decode_query(query)

    assert host == "firestorm-test.s3.us-east-1.amazonaws.com"
    assert path == "/" <> @key
    assert params["X-Amz-Expires"] == "300"
    assert params["X-Amz-SignedHeaders"] == "host"
    assert params["response-content-disposition"] == ~s(inline; filename="a.png")

    unsigned = query |> String.split("&X-Amz-Signature=") |> hd()

    canonical =
      Enum.join(
        ["GET", "/" <> @key, unsigned, "host:#{host}\n", "host", "UNSIGNED-PAYLOAD"],
        "\n"
      )

    to_sign =
      "AWS4-HMAC-SHA256\n20261101T123456Z\n20261101/us-east-1/s3/aws4_request\n" <>
        hex(:crypto.hash(:sha256, canonical))

    assert params["X-Amz-Signature"] == hex(mac(signing_key(), to_sign))
    # Spaces and quotes are percent-encoded (RFC 3986), as S3 expects.
    assert unsigned =~ "response-content-disposition=inline%3B%20filename%3D%22a.png%22"
  end

  test "the S3 storage hands viewers a presigned link" do
    assert {:redirect, url} = S3.locate(@key, "image/png", "inline")
    assert url =~ "X-Amz-Signature="
    assert url =~ "response-content-type=image%2Fpng"
  end
end
