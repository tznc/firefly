defmodule Firefly.Repo.Migrations.AddUploadsScanStatus do
  use Ecto.Migration

  # The virus scan's verdict (see Firefly.Uploads.Scanner): only "clean"
  # uploads are served.
  def change do
    alter table(:uploads) do
      add :scan_status, :string, null: false, default: "clean"
    end
  end
end
