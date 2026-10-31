defmodule FirestormWeb.Web.Api.V1.ThreadJSON do
  @moduledoc "JSON representation of threads."
  alias FirestormWeb.Forums.Thread

  def data(%Thread{} = thread) do
    Map.take(thread, [:id, :title, :slug, :inserted_at, :updated_at, :category_id])
  end
end
