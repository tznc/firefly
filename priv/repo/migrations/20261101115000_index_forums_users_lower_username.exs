defmodule FirestormWeb.Repo.Migrations.IndexForumsUsersLowerUsername do
  use Ecto.Migration

  # Mentions look users up by `lower(username)`, and @-autocomplete by a
  # `lower(username) LIKE 'prefix%'`: text_pattern_ops serves both.
  def change do
    create index(:forums_users, ["lower(username) text_pattern_ops"],
             name: :forums_users_lower_username_index
           )
  end
end
