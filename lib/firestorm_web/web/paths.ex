defmodule FirestormWeb.Web.Paths do
  @moduledoc """
  Absolute URLs for forum resources, for use outside of a request
  (emails, notifications).
  """

  use Phoenix.VerifiedRoutes,
    endpoint: FirestormWeb.Web.Endpoint,
    router: FirestormWeb.Web.Router

  def thread_url(thread), do: url(~p"/categories/#{thread.category_id}/threads/#{thread.id}")
end
