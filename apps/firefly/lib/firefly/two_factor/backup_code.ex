defmodule Firefly.TwoFactor.BackupCode do
  @moduledoc """
  A single-use backup code (see `Firefly.TwoFactor`), stored only as
  its SHA-256 hash: codes carry 80 random bits, so the hash can't be
  reversed by guessing.
  """
  use Ecto.Schema

  schema "user_backup_codes" do
    field(:code_hash, :string, redact: true)
    field(:used_at, :utc_datetime)
    belongs_to(:user, Firefly.Forums.User)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
