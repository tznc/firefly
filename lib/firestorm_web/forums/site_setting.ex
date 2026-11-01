defmodule FirestormWeb.Forums.SiteSetting do
  @moduledoc """
  A site setting an admin changed: its key and its value as text, typed by
  its definition in `FirestormWeb.SiteSettings`.
  """

  use Ecto.Schema

  schema "forums_site_settings" do
    field(:key, :string)
    field(:value, :string)

    timestamps(type: :naive_datetime_usec)
  end
end
