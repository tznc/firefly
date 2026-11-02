defmodule FirestormWeb.Repo.Migrations.AddPluginSecrets do
  use Ecto.Migration

  # The shared secret callers present to a plugin's inbound endpoints
  # (/api/plugins/:id/*), shown to staff on the plugin's page.
  def change do
    alter table(:plugins) do
      add :secret, :string
    end
  end
end
