defmodule Firefly.Repo.Migrations.AddMailingListMode do
  use Ecto.Migration

  # Mailing list mode (see Firefly.Notifications.MailingList): every post
  # by email, counted per day against the site's limit.
  def change do
    alter table(:forums_users) do
      add :mailing_list_mode, :boolean, null: false, default: false
      add :mailing_list_no_echo, :boolean, null: false, default: true
      add :mailing_list_sent_on, :date
      add :mailing_list_sent_count, :integer, null: false, default: 0
    end
  end
end
