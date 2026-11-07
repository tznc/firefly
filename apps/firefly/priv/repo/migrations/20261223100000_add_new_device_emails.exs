defmodule Firefly.Repo.Migrations.AddNewDeviceEmails do
  use Ecto.Migration

  # Whether a member is emailed when their account is logged into from a
  # new device (see Firefly.Accounts.UserSessions).
  def change do
    alter table(:forums_users) do
      add :new_device_emails, :boolean, null: false, default: true
    end
  end
end
