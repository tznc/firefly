defmodule Firefly.Themes.ThemeAsset do
  @moduledoc """
  A file a theme uses (an image or a font), stored as an upload (see
  `Firefly.Uploads`) and named, so the theme's CSS refers to it as
  `theme-asset(name)`.
  """

  use Ecto.Schema
  use Firefly.Changeset

  schema "theme_assets" do
    field(:name, :string)
    belongs_to(:theme, Firefly.Themes.Theme)
    belongs_to(:upload, Firefly.Uploads.Upload)

    timestamps(type: :utc_datetime)
  end

  def changeset(%__MODULE__{} = asset, attrs) do
    asset
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9_-]{0,39}$/,
      message: "use lowercase letters, digits, - and _"
    )
    |> unique_constraint(:name, name: :theme_assets_theme_id_name_index, message: "is taken")
  end
end
