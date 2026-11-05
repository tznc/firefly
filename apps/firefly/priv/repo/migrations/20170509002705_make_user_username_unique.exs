defmodule Firefly.Repo.Migrations.MakeUserUsernameUnique do
  use Ecto.Migration

  # Usernames and emails are case-insensitive: "Alice" and "alice" are the
  # same name (each keeps the case it was chosen in). text_pattern_ops also
  # serves @-autocomplete's `lower(username) LIKE 'prefix%'`. Accounts
  # without an email (NULL) don't collide.
  def change do
    create unique_index(:forums_users, ["lower(username) text_pattern_ops"],
             name: :forums_users_lower_username_index
           )

    create unique_index(:forums_users, ["lower(email)"], name: :forums_users_lower_email_index)
  end
end
