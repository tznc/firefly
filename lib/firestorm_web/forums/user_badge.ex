defmodule FirestormWeb.Forums.UserBadge do
  @moduledoc """
  A badge granted to a member (see `FirestormWeb.Badges`): when, by whom
  (nil: the system), for which post (badges granted per post, or earned
  with one) and why (an admin's note).
  """

  use Ecto.Schema

  alias FirestormWeb.Forums.{Badge, Post, User}

  schema "user_badges" do
    belongs_to(:badge, Badge)
    belongs_to(:user, User)
    belongs_to(:granted_by, User)
    belongs_to(:post, Post)
    field(:reason, :string)
    field(:granted_at, :utc_datetime)
  end
end
