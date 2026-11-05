defmodule Firefly.Moderation.AkismetCheck do
  @moduledoc """
  An Akismet check of a piece of content (see `Firefly.Moderation.Akismet`):
  its `kind` (`"post"`, `"message"`, `"chat"`, `"profile"`) and id, its
  author, the request's `params` (taken when it was posted; the job only
  carries this row's id), whether Akismet called it spam (nil until it
  answers), the `status` (`"queued"` until then, `"failed"` if it never
  does (the job ran out of attempts; the content stands), `"clean"`,
  `"pending"` while spam waits for staff, `"confirmed"`, `"not_spam"`) and
  the `feedback` reported back.
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
