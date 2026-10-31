defmodule FirestormWeb.Web.Api.V1.PreviewJSON do
  @moduledoc "JSON for markdown previews."
  def show(%{html: html}), do: %{data: %{html: html}}
end
