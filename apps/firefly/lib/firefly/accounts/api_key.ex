defmodule Firefly.Accounts.ApiKey do
  @moduledoc """
  An API key (see `Firefly.Accounts.ApiKeys`): a member's own (`user_id`),
  or a global key an admin created (no `user_id`), which acts as the user
  each request names. Only the key's SHA-256 is stored, with its first
  characters (`prefix`) to recognize it by.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Firefly.Accounts.User
  alias Firefly.IPRange

  schema "api_keys" do
    field(:name, :string)
    field(:token_hash, :string, redact: true)
    field(:prefix, :string)
    field(:scopes, {:array, :string}, default: [])
    field(:allowed_ips, {:array, :string}, default: [])
    field(:rate_limit, :integer)
    field(:expires_at, :utc_datetime)
    field(:revoked_at, :utc_datetime)
    field(:last_used_at, :utc_datetime)
    field(:last_used_ip, :string)

    belongs_to(:user, User)
    belongs_to(:created_by, User)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(%__MODULE__{} = key, attrs, scopes) do
    key
    |> cast(attrs, [:name, :scopes, :allowed_ips, :rate_limit, :expires_at])
    |> update_change(:allowed_ips, &clean_list/1)
    |> update_change(:scopes, &clean_list/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
    |> validate_subset(:scopes, scopes)
    |> validate_scopes()
    |> validate_number(:rate_limit, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_change(:allowed_ips, fn :allowed_ips, ranges ->
      for range <- ranges,
          IPRange.parse(range) == :error,
          do: {:allowed_ips, "#{range} isn't an address or CIDR range"}
    end)
    |> validate_change(:expires_at, fn :expires_at, at ->
      if DateTime.after?(at, DateTime.utc_now()),
        do: [],
        else: [expires_at: "must be in the future"]
    end)
  end

  defp validate_scopes(changeset) do
    if get_field(changeset, :scopes) == [],
      do: add_error(changeset, :scopes, "pick at least one scope"),
      else: changeset
  end

  # Forms send lists as text: one item per line or comma.
  defp clean_list(list) when is_list(list),
    do:
      list
      |> Enum.flat_map(&String.split(&1, [",", "\n"]))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

  defp clean_list(_other), do: []

  @doc "Whether the key is a global (admin-created) key."
  def global?(%__MODULE__{user_id: user_id}), do: is_nil(user_id)

  @doc "Whether the key can't be used any more: revoked or expired."
  def inactive?(%__MODULE__{revoked_at: revoked_at, expires_at: expires_at}) do
    revoked_at != nil or (expires_at != nil and DateTime.before?(expires_at, DateTime.utc_now()))
  end

  @doc """
  Whether a request from `ip` (a tuple, or a string) may use the key: any
  address when it lists none, else one within its addresses and ranges.
  """
  def ip_allowed?(%__MODULE__{allowed_ips: []}, _ip), do: true

  def ip_allowed?(%__MODULE__{allowed_ips: ranges}, ip) do
    parsed = for range <- ranges, {:ok, parsed} <- [IPRange.parse(range)], do: parsed
    IPRange.member?(IPRange.address(ip), parsed)
  end
end
