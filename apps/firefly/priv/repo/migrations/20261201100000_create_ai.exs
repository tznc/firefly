defmodule Firefly.Repo.Migrations.CreateAI do
  use Ecto.Migration

  # AI (see Firefly.AI): the providers admins configure (API keys encrypted
  # at rest), which provider serves each feature, and the daily usage log
  # quotas and the usage report read.
  def change do
    create table(:ai_providers) do
      add :name, :string, null: false
      add :adapter, :string, null: false
      add :base_url, :string, null: false
      add :api_key, :binary
      add :model, :string, null: false
      add :embedding_model, :string
      add :max_tokens, :integer, null: false
      add :timeout_seconds, :integer, null: false
      add :allow_private, :boolean, null: false, default: false

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:ai_providers, [:name])

    create table(:ai_features, primary_key: false) do
      add :feature, :string, primary_key: true
      add :provider_id, references(:ai_providers, on_delete: :nilify_all)
      add :enabled, :boolean, null: false, default: false
      add :staff_only, :boolean, null: false, default: false

      timestamps(type: :naive_datetime_usec)
    end

    create table(:ai_usage) do
      add :day, :date, null: false
      add :feature, :string, null: false
      # Nil: work the system did on its own (no member asked).
      add :user_id, references(:forums_users, on_delete: :delete_all)
      add :requests, :integer, null: false, default: 0
      add :input_tokens, :bigint, null: false, default: 0
      add :output_tokens, :bigint, null: false, default: 0
    end

    create unique_index(:ai_usage, [:day, :feature, :user_id], nulls_distinct: false)
    create index(:ai_usage, [:user_id, :day])
  end
end
