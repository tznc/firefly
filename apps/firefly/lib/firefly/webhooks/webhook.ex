defmodule Firefly.Webhooks.Webhook do
  @moduledoc """
  An outbound webhook (see `Firefly.Webhooks`): where to POST
  (`payload_url`), the `secret` signing each delivery, which events
  (`wildcard`: all of them, else the `event_types`) and, optionally, only
  those in some categories, with some tags or by members of some groups.
  `failure_count` counts failed attempts in a row; too many turn it off
  (`active`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types ~w(topic post user category tag group flag review like chat)

  schema "webhooks" do
    field(:payload_url, :string)
    field(:secret, Firefly.Encrypted.Binary, redact: true)
    field(:content_type, :string, default: "application/json")
    field(:wildcard, :boolean, default: false)
    field(:event_types, {:array, :string}, default: [])
    field(:category_ids, {:array, :integer}, default: [])
    field(:tag_names, {:array, :string}, default: [])
    field(:group_ids, {:array, :integer}, default: [])
    field(:active, :boolean, default: true)
    field(:failure_count, :integer, default: 0)
    field(:last_status, :string)
    field(:last_delivery_at, :utc_datetime)

    timestamps(type: :naive_datetime_usec)
  end

  @doc "The event types a webhook can pick, in display order."
  def types, do: @types

  def changeset(%__MODULE__{} = webhook, attrs) do
    attrs = attrs |> split_tags() |> drop_blanks()

    webhook
    |> cast(attrs, [
      :payload_url,
      :secret,
      :wildcard,
      :event_types,
      :category_ids,
      :tag_names,
      :group_ids,
      :active
    ])
    |> update_change(:payload_url, &String.trim/1)
    |> validate_required([:payload_url])
    |> validate_length(:payload_url, max: 2000)
    |> validate_length(:secret, min: 12, max: 200)
    |> validate_change(:payload_url, &url_errors/2)
    |> validate_subset(:event_types, @types)
    |> validate_events()
    |> reactivate()
  end

  # Tags come from a text field, comma- or space-separated.
  defp split_tags(%{"tag_names" => tags} = attrs) when is_binary(tags),
    do: %{
      attrs
      | "tag_names" => tags |> String.downcase() |> String.split([",", " "], trim: true)
    }

  defp split_tags(attrs), do: attrs

  # Forms send a blank entry so that unticking every box still sends the field.
  defp drop_blanks(attrs) do
    Map.new(attrs, fn
      {key, list} when is_list(list) -> {key, Enum.reject(list, &(&1 == ""))}
      pair -> pair
    end)
  end

  defp url_errors(:payload_url, url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        []

      _ ->
        [payload_url: "must be an http or https URL"]
    end
  end

  defp validate_events(changeset) do
    if get_field(changeset, :wildcard) or get_field(changeset, :event_types) != [],
      do: changeset,
      else: add_error(changeset, :event_types, "pick at least one, or send every event")
  end

  # Turning a webhook back on gives it a clean slate.
  defp reactivate(changeset) do
    if get_change(changeset, :active) == true,
      do: put_change(changeset, :failure_count, 0),
      else: changeset
  end
end
