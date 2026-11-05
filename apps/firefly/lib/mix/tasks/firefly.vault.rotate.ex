defmodule Mix.Tasks.Firefly.Vault.Rotate do
  use Boundary, classify_to: Firefly
  @shortdoc "Re-encrypts the database's secrets with the current vault key"

  @moduledoc """
  Re-encrypts every secret in the database that isn't encrypted with the
  current vault key (`FIREFLY_VAULT_KEY`), after a rotation moved the old
  key to `FIREFLY_VAULT_RETIRED_KEYS` (see `Firefly.Vault`):

      mix firefly.vault.rotate

  In a release: `bin/firefly eval Firefly.Release.rotate_vault`. It is safe
  to run again, and while the forum runs: values already under the current
  key are left alone.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    Mix.Task.run("app.start")

    for {{table, column}, count} <- Firefly.Vault.rotate() do
      Mix.shell().info("#{table}.#{column}: #{count} re-encrypted")
    end
  end
end
