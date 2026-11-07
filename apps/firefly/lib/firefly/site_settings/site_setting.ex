defmodule Firefly.SiteSettings.SiteSetting do
  @moduledoc """
  A site setting an admin changed: its key and its value as text, typed by
  its definition in `Firefly.SiteSettings`. A secret setting's value is in
  `secret_value` instead, encrypted at rest (see `Firefly.Vault`), and
  `value` is empty.
  """

  use Ecto.Schema

  schema "forums_site_settings" do
    field(:key, :string)
    field(:value, :string)
    field(:secret_value, Firefly.Encrypted.Binary, redact: true)

    timestamps(type: :naive_datetime_usec)
  end
end
