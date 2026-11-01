defmodule FirestormWeb.Web.Api.V1.UploadSignatureJSON do
  @moduledoc "JSON for S3 presigned POST policies."

  def show(%{upload_signature: signature}), do: %{data: signature}
end
