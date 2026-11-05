defmodule Firefly.Accounts.TwoFactor.Credential do
  @moduledoc """
  A WebAuthn credential (a security key or a passkey; see
  `Firefly.Accounts.WebAuthn`): the
  authenticator's credential id, its public key (a COSE key, stored as an
  Erlang term), the signature counter it last reported and the name its
  owner gave it.
  """
  use Ecto.Schema

  use Firefly.Changeset

  schema "webauthn_credentials" do
    field(:credential_id, :binary)
    field(:public_key, :binary, redact: true)
    field(:sign_count, :integer, default: 0)
    field(:name, :string)
    # A discoverable credential that logs in on its own (see Firefly.Accounts.Passkeys).
    field(:passkey, :boolean, default: false)
    field(:last_used_at, :utc_datetime)
    belongs_to(:user, Firefly.Accounts.User)

    timestamps(type: :utc_datetime)
  end

  @doc "Validates the name a credential is saved or renamed with."
  def name_changeset(credential, attrs) do
    credential
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 60)
  end

  @doc "The credential's public key (a COSE key map)."
  # Sobelow: a term this app encoded when the passkey was registered, decoded with :safe.
  # sobelow_skip ["Misc.BinToTerm"]
  def cose_key(%__MODULE__{public_key: key}), do: :erlang.binary_to_term(key, [:safe])
end
