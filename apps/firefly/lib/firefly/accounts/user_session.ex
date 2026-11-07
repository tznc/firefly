defmodule Firefly.Accounts.UserSession do
  @moduledoc """
  A logged-in browser (see `Firefly.Accounts.UserSessions`): its cookie
  holds a random token, of which only the SHA-256 (`token_hash`) is stored.
  `remember` sessions outlive the browser session (the "keep me logged in"
  cookie). `ip`, `user_agent` and `device` (a label like "Firefox on
  macOS") are from the last time it was seen; `ip` is truncated after the
  `ip_retention_days` setting.
  """

  use Ecto.Schema

  alias Firefly.Accounts.User

  schema "user_sessions" do
    field(:token_hash, :binary, redact: true)
    field(:remember, :boolean, default: false)
    field(:ip, :string)
    field(:user_agent, :string)
    field(:device, :string)
    field(:last_seen_at, :utc_datetime)
    belongs_to(:user, User)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
