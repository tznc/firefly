defmodule Firefly.Repo.Migrations.AddDigestEmails do
  use Ecto.Migration

  # Digest emails (see Firefly.Digests): how often a member wants one
  # (nil: the site's default) and when the last one was sent, which also
  # keeps two nodes from sending the same one.
  def change do
    alter table(:forums_users) do
      add :digest_frequency, :string
      add :last_digest_at, :utc_datetime
    end
  end
end
