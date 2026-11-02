defmodule FirestormWeb.Repo.Migrations.CreateCustomEmoji do
  use Ecto.Migration

  # Emoji admins add (see FirestormWeb.Emoji): `:name:` in a post shows the
  # image, an upload of the "emoji" variant.
  def change do
    create table(:custom_emoji) do
      add :name, :string, null: false
      add :upload_id, references(:uploads, on_delete: :delete_all), null: false
      add :created_by_id, references(:forums_users, on_delete: :nilify_all)

      timestamps(type: :naive_datetime_usec)
    end

    create unique_index(:custom_emoji, [:name])
  end
end
