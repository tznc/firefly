defmodule Firefly.Repo.Migrations.AddAdminPanel do
  use Ecto.Migration

  # What the staff admin at /staff needs: approving new accounts, the
  # addresses members came from, screened emails, IPs and URLs, the log of
  # sent emails, and per-group permissions and member defaults on
  # categories.
  def change do
    # Existing accounts are approved; with `must_approve_users` on, new ones
    # wait for staff (see Firefly.Accounts.UserAdmin).
    alter table(:forums_users) do
      add :approved, :boolean, null: false, default: true
      add :approved_by_id, references(:forums_users, on_delete: :nilify_all)
      add :approved_at, :utc_datetime
    end

    create index(:forums_users, [:approved], where: "NOT approved")

    create table(:user_ips) do
      add :user_id, references(:forums_users, on_delete: :delete_all), null: false
      add :ip, :string, size: 45, null: false
      add :first_seen_at, :utc_datetime, null: false
      add :last_seen_at, :utc_datetime, null: false
    end

    create unique_index(:user_ips, [:user_id, :ip])
    create index(:user_ips, [:ip])

    create table(:screened_items) do
      add :kind, :string, null: false
      add :value, :string, null: false
      add :match_count, :integer, null: false, default: 0
      add :last_matched_at, :utc_datetime
      add :created_by_id, references(:forums_users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:screened_items, ["kind", "lower(value)"],
             name: :screened_items_kind_value_index
           )

    create table(:email_logs) do
      add :to, :string, null: false
      add :subject, :text, null: false
      add :template, :string, null: false
      add :status, :string, null: false
      add :error, :text
      add :user_id, references(:forums_users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:email_logs, [:inserted_at])
    create index(:email_logs, [:user_id])

    # A restricted category's groups each get a permission: `full` (start
    # threads and reply), `create_post` (reply) or `readonly`.
    alter table(:forums_category_roles) do
      add :permission, :string, null: false, default: "full"
    end

    # New members start at this notification level for the category.
    alter table(:forums_categories) do
      add :default_notification_level, :string
    end
  end
end
