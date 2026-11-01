defmodule FirestormWeb.Forums.StaffAction do
  @moduledoc """
  One entry in the staff log (see `FirestormWeb.StaffLog`): who did what to
  which target. `details` holds what the log needs to show the action even
  after the target is gone, e.g. a thread's title, or the before/after
  values of an edit as `%{"field" => %{"before" => old, "after" => new}}`.
  """

  use Ecto.Schema

  alias FirestormWeb.Forums.User

  schema "forums_staff_actions" do
    field(:action, :string)
    field(:target_type, :string)
    field(:target_id, :integer)
    field(:details, :map, default: %{})
    belongs_to(:actor, User)

    timestamps(type: :naive_datetime_usec, updated_at: false)
  end
end
