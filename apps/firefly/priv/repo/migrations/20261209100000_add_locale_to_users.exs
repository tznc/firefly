defmodule Firefly.Repo.Migrations.AddLocaleToUsers do
  use Ecto.Migration

  # The language a member reads the interface in (see FireflyWeb.Locale);
  # null follows their browser, then the site's default.
  def change do
    alter table(:forums_users) do
      add :locale, :string
    end
  end
end
