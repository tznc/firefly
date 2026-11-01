defmodule FirestormWeb.Uploads.AWS.UploadSignatureTest do
  use ExUnit.Case, async: true

  alias FirestormWeb.Uploads.AWS.UploadSignature

  @key "uploads/abc/image.jpg"

  setup do
    {:ok, signature: UploadSignature.signature(@key, "image/jpeg")}
  end

  test "signs the base64 policy with HMAC-SHA1 of the secret key", %{signature: sig} do
    expected = :crypto.mac(:hmac, :sha, "test-secret-access-key", sig.policy) |> Base.encode64()
    assert sig.signature == expected
  end

  test "encodes a policy restricted to the bucket, key and content type", %{signature: sig} do
    policy = sig.policy |> Base.decode64!() |> Jason.decode!()

    assert %{"bucket" => "firestorm-test"} in policy["conditions"]
    assert %{"acl" => "public-read"} in policy["conditions"]
    assert ["starts-with", "$Content-Type", "image/jpeg"] in policy["conditions"]
    assert ["starts-with", "$key", @key] in policy["conditions"]

    {:ok, expiration, 0} = DateTime.from_iso8601(policy["expiration"])
    diff = DateTime.diff(expiration, DateTime.utc_now(), :second)
    assert diff in 3590..3600
  end

  test "returns the fields the client needs to post to S3", %{signature: sig} do
    assert sig.key == @key
    assert sig.content_type == "image/jpeg"
    assert sig.action == "https://s3-us-east-1.amazonaws.com/firestorm-test"
    assert sig.aws_access_key_id == "test-access-key-id"
    assert sig.date =~ ~r/\A\d{8}\z/
    assert sig.credential == "test-access-key-id/#{sig.date}/us-east-1/s3/aws4_request"
  end

  test "get_date/0 is today's UTC date as YYYYMMDD" do
    assert UploadSignature.get_date() == Calendar.strftime(DateTime.utc_now(), "%Y%m%d")
  end
end
