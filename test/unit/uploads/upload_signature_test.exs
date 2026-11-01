defmodule FirestormWeb.Uploads.AWS.UploadSignatureTest do
  use ExUnit.Case, async: true

  alias FirestormWeb.Uploads
  alias FirestormWeb.Uploads.AWS.UploadSignature

  @key "uploads/abc/image.jpg"
  @now ~U[2026-11-01 12:34:56Z]

  setup do
    {:ok, sig: UploadSignature.signature(@key, "image/jpeg", 10_000_000, @now)}
  end

  test "posts to the bucket's virtual-hosted endpoint", %{sig: sig} do
    assert sig.action == "https://firestorm-test.s3.us-east-1.amazonaws.com"
    assert sig.key == @key
  end

  test "uses AWS Signature Version 4 form fields", %{sig: %{fields: fields}} do
    assert fields["key"] == @key
    assert fields["Content-Type"] == "image/jpeg"
    assert fields["x-amz-algorithm"] == "AWS4-HMAC-SHA256"
    assert fields["x-amz-credential"] == "test-access-key-id/20261101/us-east-1/s3/aws4_request"
    assert fields["x-amz-date"] == "20261101T123456Z"
    refute Map.has_key?(fields, "AWSAccessKeyId")
  end

  test "signs the policy with the SigV4 signing key", %{sig: %{fields: fields}} do
    # Independently derived signing key, per the AWS SigV4 spec
    k_date = :crypto.mac(:hmac, :sha256, "AWS4test-secret-access-key", "20261101")
    k_region = :crypto.mac(:hmac, :sha256, k_date, "us-east-1")
    k_service = :crypto.mac(:hmac, :sha256, k_region, "s3")
    k_signing = :crypto.mac(:hmac, :sha256, k_service, "aws4_request")

    expected =
      :crypto.mac(:hmac, :sha256, k_signing, fields["policy"]) |> Base.encode16(case: :lower)

    assert fields["x-amz-signature"] == expected
  end

  test "restricts the exact key, content type and size, and expires soon", %{
    sig: %{fields: fields}
  } do
    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert %{"bucket" => "firestorm-test"} in policy["conditions"]
    assert %{"key" => @key} in policy["conditions"]
    assert %{"Content-Type" => "image/jpeg"} in policy["conditions"]
    assert ["content-length-range", 1, 10_000_000] in policy["conditions"]
    refute Enum.any?(policy["conditions"], &match?(["starts-with" | _], &1))

    {:ok, expiration, 0} = DateTime.from_iso8601(policy["expiration"])
    assert DateTime.diff(expiration, @now) == 600
  end

  describe "Uploads.sign/2" do
    test "refuses HTML, SVG and other active content" do
      for type <- ~w(text/html image/svg+xml application/javascript application/x-msdownload) do
        assert {:error, "unsupported file type"} = Uploads.sign("x", type)
      end
    end

    test "stores uploads under a random prefix with a safe filename" do
      assert {:ok, %{key: key}} = Uploads.sign("../../etc/pass wd<script>.png", "image/png")
      assert key =~ ~r"\Auploads/[0-9a-f-]{36}/pass_wd_script_\.png\z"
    end
  end
end
