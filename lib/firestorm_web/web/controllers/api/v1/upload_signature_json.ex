defmodule FirestormWeb.Web.Api.V1.UploadSignatureJSON do
  @moduledoc "JSON for S3 upload signatures."
  @fields [
    :key,
    :date,
    :content_type,
    :acl,
    :success_action_status,
    :action,
    :aws_access_key_id,
    :credential,
    :policy,
    :signature
  ]

  def show(%{upload_signature: signature}), do: %{data: Map.take(signature, @fields)}
end
