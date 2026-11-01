defmodule FirestormWeb.Uploads.AWS.UploadSignature do
  @moduledoc """
  Presigned S3 POST policies (AWS Signature Version 4) so the browser can
  upload directly to S3.

  The policy pins the exact key and content type, caps the size, and expires
  after a few minutes.
  """

  @service "s3"
  @algorithm "AWS4-HMAC-SHA256"
  @expires_in_seconds 600

  @doc """
  Returns `%{action: bucket_url, key: key, fields: form_fields}`; POST the
  fields plus a `file` field to `action`.
  """
  def signature(key, content_type, max_size, now \\ DateTime.utc_now()) do
    now = DateTime.truncate(now, :second)
    date = Calendar.strftime(now, "%Y%m%d")
    credential = "#{aws_config()[:access_key_id]}/#{date}/#{region()}/#{@service}/aws4_request"

    fields = %{
      "key" => key,
      "Content-Type" => content_type,
      "acl" => "public-read",
      "success_action_status" => "201",
      "x-amz-algorithm" => @algorithm,
      "x-amz-credential" => credential,
      "x-amz-date" => Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    }

    policy =
      %{
        expiration: now |> DateTime.add(@expires_in_seconds) |> DateTime.to_iso8601(),
        conditions:
          [%{"bucket" => bucket_name()}, ["content-length-range", 1, max_size]] ++
            Enum.map(fields, fn {name, value} -> %{name => value} end)
      }
      |> Jason.encode!()
      |> Base.encode64()

    %{
      action: bucket_url(),
      key: key,
      fields:
        Map.merge(fields, %{
          "policy" => policy,
          "x-amz-signature" => sign(policy, date)
        })
    }
  end

  @doc false
  def signing_key(date) do
    ("AWS4" <> secret_access_key())
    |> hmac(date)
    |> hmac(region())
    |> hmac(@service)
    |> hmac("aws4_request")
  end

  defp sign(policy, date),
    do: date |> signing_key() |> hmac(policy) |> Base.encode16(case: :lower)

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp bucket_name, do: aws_config()[:bucket]
  defp region, do: aws_config()[:region]
  defp secret_access_key, do: aws_config()[:secret_access_key]

  defp bucket_url, do: "https://#{bucket_name()}.s3.#{region()}.amazonaws.com"

  defp aws_config, do: Application.get_env(:firestorm_web, :aws)
end
