defmodule FirestormWeb.Uploads.AWS.SigV4 do
  @moduledoc """
  AWS Signature Version 4 for the S3 upload storage: signed requests the
  server makes (`PUT` and `DELETE` an object) and presigned `GET` links
  that expire, so a private bucket's files reach only the viewers
  `FirestormWeb.Web.UploadController` let through.

  Configured by `config :firestorm_web, :aws` (`access_key_id`,
  `secret_access_key`, `bucket`, `region`; `FIREFLY_AWS_*`).
  """

  @service "s3"
  @algorithm "AWS4-HMAC-SHA256"

  @doc """
  The URL and headers of a signed request for `key`: `method` (`"PUT"` or
  `"DELETE"`) with `body` and extra `headers` (lowercase names).
  """
  def request(method, key, body \\ "", headers \\ [], now \\ DateTime.utc_now()) do
    {date, timestamp} = stamps(now)
    payload_hash = hex(:crypto.hash(:sha256, body))

    headers =
      Enum.sort([
        {"host", host()},
        {"x-amz-content-sha256", payload_hash},
        {"x-amz-date", timestamp}
        | headers
      ])

    signed_headers = Enum.map_join(headers, ";", &elem(&1, 0))

    canonical =
      Enum.join(
        [
          method,
          path(key),
          "",
          Enum.map_join(headers, "", fn {name, value} -> "#{name}:#{String.trim(value)}\n" end),
          signed_headers,
          payload_hash
        ],
        "\n"
      )

    authorization =
      "#{@algorithm} Credential=#{credential(date)}, SignedHeaders=#{signed_headers}, " <>
        "Signature=#{signature(canonical, date, timestamp)}"

    {"https://#{host()}#{path(key)}", [{"authorization", authorization} | headers]}
  end

  @doc """
  A link to `key` that works for `expires_in` seconds. `response` sets the
  response headers S3 sends with it (e.g. `"response-content-disposition"`).
  """
  def presigned_url(key, expires_in, response \\ %{}, now \\ DateTime.utc_now()) do
    {date, timestamp} = stamps(now)

    query =
      response
      |> Map.merge(%{
        "X-Amz-Algorithm" => @algorithm,
        "X-Amz-Credential" => credential(date),
        "X-Amz-Date" => timestamp,
        "X-Amz-Expires" => Integer.to_string(expires_in),
        "X-Amz-SignedHeaders" => "host"
      })
      |> Enum.sort()
      |> Enum.map_join("&", fn {name, value} -> "#{encode(name)}=#{encode(value)}" end)

    canonical =
      Enum.join(["GET", path(key), query, "host:#{host()}\n", "host", "UNSIGNED-PAYLOAD"], "\n")

    "https://#{host()}#{path(key)}?#{query}&X-Amz-Signature=#{signature(canonical, date, timestamp)}"
  end

  @doc false
  def signing_key(date) do
    ("AWS4" <> config(:secret_access_key))
    |> hmac(date)
    |> hmac(config(:region))
    |> hmac(@service)
    |> hmac("aws4_request")
  end

  defp signature(canonical, date, timestamp) do
    scope = "#{date}/#{config(:region)}/#{@service}/aws4_request"

    to_sign =
      Enum.join([@algorithm, timestamp, scope, hex(:crypto.hash(:sha256, canonical))], "\n")

    date |> signing_key() |> hmac(to_sign) |> hex()
  end

  defp stamps(now) do
    now = DateTime.truncate(now, :second)
    {Calendar.strftime(now, "%Y%m%d"), Calendar.strftime(now, "%Y%m%dT%H%M%SZ")}
  end

  defp credential(date),
    do: "#{config(:access_key_id)}/#{date}/#{config(:region)}/#{@service}/aws4_request"

  defp host, do: "#{config(:bucket)}.s3.#{config(:region)}.amazonaws.com"

  # Keys are hex digests, slashes and an extension: nothing to escape but
  # still encoded per segment, as SigV4 requires.
  defp path(key), do: "/" <> Enum.map_join(String.split(key, "/"), "/", &encode/1)

  # RFC 3986: everything but unreserved characters is percent-encoded.
  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(binary), do: Base.encode16(binary, case: :lower)

  defp config(key), do: Application.get_env(:firestorm_web, :aws)[key]
end
