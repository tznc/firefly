defmodule FirestormWeb.Web.Paths do
  @moduledoc """
  Absolute URLs for forum resources, for use outside of a request
  (emails, notifications).
  """

  use Phoenix.VerifiedRoutes,
    endpoint: FirestormWeb.Web.Endpoint,
    router: FirestormWeb.Web.Router

  def confirmation_url(token), do: url(~p"/confirm/#{token}")

  def password_reset_url(token), do: url(~p"/reset-password/#{token}")

  def notification_settings_url, do: url(~p"/settings/notifications")

  def user_url(user), do: url(~p"/users/#{user.id}")

  def category_url(category), do: url(~p"/categories/#{category.id}")

  def conversation_url(conversation), do: url(~p"/messages/#{conversation.id}")

  def thread_url(thread), do: url(~p"/categories/#{thread.category_id}/threads/#{thread.id}")
end
