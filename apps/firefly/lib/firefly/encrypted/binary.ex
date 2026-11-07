defmodule Firefly.Encrypted.Binary do
  @moduledoc """
  An Ecto type for a secret kept encrypted at rest by `Firefly.Vault`, in
  a `:binary` (`bytea`) column. Fields of this type are also `redact: true`,
  and their columns are listed in `Firefly.Vault.columns/0`.
  """

  use Cloak.Ecto.Binary, vault: Firefly.Vault
end
