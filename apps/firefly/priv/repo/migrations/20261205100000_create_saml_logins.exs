defmodule Firefly.Repo.Migrations.CreateSamlLogins do
  use Ecto.Migration

  # SAML logins (see Firefly.Accounts.Auth.SAML): each request we sent the
  # browser off with, until its answer is used or it expires, and the ids
  # of assertions already used, so none is accepted twice.
  def change do
    create table(:saml_requests, primary_key: false) do
      add :id, :string, primary_key: true
      add :return_to, :string, null: false
      # The verified answer, once the identity provider's response came.
      add :result, :map
      add :expires_at, :utc_datetime, null: false
    end

    create index(:saml_requests, [:expires_at])

    create table(:saml_assertions, primary_key: false) do
      add :id, :string, primary_key: true
      add :expires_at, :utc_datetime, null: false
    end

    create index(:saml_assertions, [:expires_at])
  end
end
