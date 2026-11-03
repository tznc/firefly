defmodule Firefly.Repo.Migrations.AddKeyboardShortcutsToUsers do
  use Ecto.Migration

  # Whether the member wants the keyboard shortcuts (see the
  # KeyboardShortcuts hook); on unless they turn them off.
  def change do
    alter table(:forums_users) do
      add :keyboard_shortcuts, :boolean, null: false, default: true
    end
  end
end
