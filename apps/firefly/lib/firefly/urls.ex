defmodule Firefly.URLs do
  @moduledoc """
  Absolute URLs for forum resources, for use outside of a request
  (emails, notifications, plugin events).

  The paths are the web interface's routes, built the way its verified
  routes (`~p`) build them: each dynamic segment is URI-encoded, under the
  endpoint's base URL (see `Firefly.Endpoint`). A test in the web app checks
  each one is routed.
  """

  alias Firefly.Endpoint

  def confirmation_url(token), do: url(["confirm", token])

  def password_reset_url(token), do: url(["reset-password", token])

  def magic_link_url(token), do: url(["login", "email", token])

  def notification_settings_url, do: url(["settings", "notifications"])

  def user_url(user), do: url(["users", user.id])

  def invite_url(key), do: url(["invites", key])

  @doc "A group's page (`tab`: e.g. `\"members\"`, `\"requests\"`)."
  def group_url(group, tab \\ nil)
  def group_url(group, nil), do: url(["groups", group.name])
  def group_url(group, tab), do: url(["groups", group.name, tab])

  def badge_url(badge), do: url(["badges", badge.id])

  def digest_unsubscribe_url(token), do: url(["email", "unsubscribe", token])

  def category_url(category), do: url(["categories", category.id])

  def conversation_url(conversation), do: url(["messages", conversation.id])

  def thread_url(thread), do: url(["categories", thread.category_id, "threads", thread.id])

  defp url(segments) do
    path = Enum.map_join(segments, &["/", encode(&1)])
    Endpoint.url() <> Endpoint.path(path)
  end

  defp encode(segment) when is_integer(segment), do: Integer.to_string(segment)
  defp encode(segment) when is_binary(segment), do: URI.encode(segment, &URI.char_unreserved?/1)
end
