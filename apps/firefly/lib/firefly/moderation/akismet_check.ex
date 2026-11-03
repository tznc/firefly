defmodule Firefly.Moderation.AkismetCheck do
  @moduledoc """
  Akismet's verdict on a piece of content (see `Firefly.Moderation.Akismet`):
  its `kind` (`"post"`, `"message"`, `"chat"`, `"profile"`) and id, its
  author, whether Akismet called it spam, the review `status` (`"clean"`,
  `"pending"` while spam waits for staff, `"confirmed"`, `"not_spam"`),
  the `params` sent (to report it back) and the `feedback` reported.
  """
  use Ecto.Schema

  alias Firefly.Accounts.User

  @kinds ~w(post message chat profile)

  schema "akismet_checks" do
    field(:kind, :string)
    field(:subject_id, :integer)
    field(:spam, :boolean)
    field(:status, :string)
    field(:params, :map, default: %{})
    field(:feedback, :string)
    field(:reviewed_at, :utc_datetime)
    belongs_to(:user, User)
    belongs_to(:reviewed_by, User)

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
end
