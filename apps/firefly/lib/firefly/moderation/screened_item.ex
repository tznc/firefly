defmodule Firefly.Moderation.ScreenedItem do
  @moduledoc """
  An entry of a screening list (see `Firefly.Moderation.Screening`): an
  email address or pattern, an IP address or range, or a URL's domain,
  with how often it blocked something and when it last did.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(email ip url)

  schema "screened_items" do
    field(:kind, :string)
    field(:value, :string)
    field(:match_count, :integer, default: 0)
    field(:last_matched_at, :utc_datetime)
    belongs_to(:created_by, Firefly.Accounts.User)

    timestamps(type: :utc_datetime)
  end

  @doc "The lists: `email`, `ip` and `url`."
  def kinds, do: @kinds

  def changeset(%__MODULE__{} = item, attrs) do
    item
    |> cast(attrs, [:kind, :value])
    |> update_change(:value, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:kind, :value])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:value, max: 200)
    |> validate_value()
    |> unique_constraint(:value,
      name: :screened_items_kind_value_index,
      message: "is already listed"
    )
  end

  # Emails: an address, or `*@domain` for a whole domain (`*` matches any
  # run of characters). IPs: an address or a CIDR range. URLs: a domain
  # (its subdomains too) or a URL whose domain is taken.
  defp validate_value(%{valid?: false} = changeset), do: changeset

  defp validate_value(changeset) do
    value = get_field(changeset, :value)

    case get_field(changeset, :kind) do
      "email" ->
        if value =~ ~r/^[^\s@]+@[^\s@]+$/,
          do: changeset,
          else:
            add_error(
              changeset,
              :value,
              "must be an email address, or a pattern like *@spam.example"
            )

      "ip" ->
        case Firefly.IPRange.parse(value) do
          {:ok, _range} ->
            changeset

          _error ->
            add_error(changeset, :value, "must be an IP address or a range like 10.0.0.0/8")
        end

      "url" ->
        case domain(value) do
          nil -> add_error(changeset, :value, "must be a domain or a URL")
          host -> put_change(changeset, :value, host)
        end
    end
  end

  @doc "The domain of a URL or bare domain (lowercased, without `www.`), or nil."
  def domain(value) do
    url = if value =~ ~r{^[a-z][a-z0-9+.-]*://}i, do: value, else: "http://" <> value

    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        host = host |> String.downcase() |> String.trim_leading("www.")
        if host =~ ~r/^[a-z0-9.-]+\.[a-z0-9-]+$/, do: host

      _ ->
        nil
    end
  end
end
