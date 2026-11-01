defmodule FirestormWeb.Web.Authorization do
  @moduledoc """
  View and LiveView helpers for `FirestormWeb.Forums.Policy`.
  """

  alias FirestormWeb.Forums

  @doc "Whether `user` may perform `action` (on `resource`)."
  def can?(user, action, resource \\ %{}), do: Bodyguard.permit?(Forums, action, user, resource)

  @doc "The message shown when an action is refused."
  def denied_message(nil), do: "You must be logged in to access this page."
  def denied_message(_user), do: "You are not allowed to do that."
end
