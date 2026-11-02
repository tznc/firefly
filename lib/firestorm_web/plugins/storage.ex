defmodule FirestormWeb.Plugins.Storage do
  @moduledoc """
  Each plugin's own key-value storage (host functions `kv.get`, `kv.set`,
  `kv.delete`, `kv.list`). Values are any JSON. Keys are 1-200 characters.

  Every function takes a scope: a plugin id for the plugin's global store,
  or `{plugin_id, user_id}` for what it keeps for one member. The scopes are
  separate namespaces: the same key in the global store and in two members'
  stores is three different values.

  Quotas (`config :firestorm_web, FirestormWeb.Plugins.Storage`):
  `:max_keys` (1,000) and `:max_bytes` (1 MB of encoded values) for a
  plugin's global store, `:user_max_keys` (200) and `:user_max_bytes`
  (64 KB) for each member's store of each plugin. A plugin only ever sees
  its own keys; uninstalling it deletes them, in every scope. A member's
  entries are in their account export and go with their account (see
  `export/1` and `delete_user/1`).
  """

  import Ecto.Query

  alias FirestormWeb.Repo
  alias FirestormWeb.Plugins.StoredValue

  @typedoc "A plugin id (global) or `{plugin_id, user_id}` (one member's)."
  @type scope :: String.t() | {String.t(), pos_integer()}

  @doc "The value under `key`, or nil."
  @spec get(scope(), String.t()) :: term()
  def get(scope, key) do
    case Repo.one(where(scoped(scope), key: ^key)) do
      %StoredValue{value: %{"v" => value}} -> value
      nil -> nil
    end
  end

  @doc "Stores `value` under `key`: `:ok` or `{:error, message}` (bad key, over quota)."
  @spec put(scope(), String.t(), term()) :: :ok | {:error, String.t()}
  def put(scope, key, value) do
    size = byte_size(Jason.encode!(value))

    with :ok <- check_key(key),
         {:ok, :stored} <- store(scope, key, value, size),
         do: :ok
  end

  defp store(scope, key, value, size) do
    {plugin_id, user_id} = split(scope)

    Repo.transact(fn ->
      # Serializes writes to one scope, so two can't both squeeze under its quota.
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [lock_name(scope)])
      existing = Repo.one(where(scoped(scope), key: ^key))

      with :ok <- check_quota(scope, existing, size) do
        row = existing || %StoredValue{plugin_id: plugin_id, user_id: user_id, key: key}
        Repo.insert_or_update!(Ecto.Changeset.change(row, value: %{"v" => value}, size: size))
        {:ok, :stored}
      end
    end)
  end

  defp lock_name({plugin_id, user_id}), do: "plugin_kv:#{plugin_id}:#{user_id}"
  defp lock_name(plugin_id), do: "plugin_kv:" <> plugin_id

  defp check_key(key) do
    if is_binary(key) and String.length(key) in 1..200,
      do: :ok,
      else: {:error, "keys must be text of 1 to 200 characters"}
  end

  defp check_quota(scope, existing, size) do
    %{keys: count, bytes: bytes} = usage(scope)
    {count, bytes} = if existing, do: {count - 1, bytes - existing.size}, else: {count, bytes}
    {max_keys, max_bytes} = quotas(scope)

    cond do
      count + 1 > max_keys -> {:error, "storage quota exceeded: too many keys"}
      bytes + size > max_bytes -> {:error, "storage quota exceeded: too much data"}
      true -> :ok
    end
  end

  defp quotas({_plugin_id, _user_id}),
    do: {quota(:user_max_keys, 200), quota(:user_max_bytes, 65_536)}

  defp quotas(_plugin_id), do: {quota(:max_keys, 1_000), quota(:max_bytes, 1_048_576)}

  defp quota(key, default),
    do: Application.get_env(:firestorm_web, __MODULE__, [])[key] || default

  @doc "Deletes `key`."
  @spec delete(scope(), String.t()) :: :ok
  def delete(scope, key) do
    Repo.delete_all(where(scoped(scope), key: ^key))
    :ok
  end

  @doc "The keys starting with `prefix`, sorted, at most 1,000."
  @spec list(scope(), String.t()) :: [String.t()]
  def list(scope, prefix \\ "") do
    scope
    |> scoped()
    |> where([v], like(v.key, ^(escape_like(prefix) <> "%")))
    |> order_by(:key)
    |> limit(1_000)
    |> select([v], v.key)
    |> Repo.all()
  end

  defp escape_like(prefix), do: String.replace(prefix, ~r/([\\%_])/, "\\\\\\1")

  @doc "How much a scope stores: `%{keys, bytes}`."
  @spec usage(scope()) :: %{keys: non_neg_integer(), bytes: non_neg_integer()}
  def usage(scope) do
    {keys, bytes} =
      scope
      |> scoped()
      |> select([v], {count(v.id), coalesce(sum(v.size), 0)})
      |> Repo.one()

    %{keys: keys, bytes: bytes}
  end

  @doc "Deletes everything `plugin_id` stored, globally and for every member (on uninstall)."
  def clear(plugin_id), do: Repo.delete_all(where(StoredValue, plugin_id: ^plugin_id))

  @doc "The member's own entries, `%{plugin_id => %{key => value}}`, for their account export."
  def export(%{id: user_id}) do
    StoredValue
    |> where(user_id: ^user_id)
    |> order_by([:plugin_id, :key])
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, acc ->
      put_in(acc, [Access.key(row.plugin_id, %{}), row.key], row.value["v"])
    end)
  end

  @doc "Deletes the member's entries in every plugin (on account deletion)."
  def delete_user(%{id: user_id}), do: Repo.delete_all(where(StoredValue, user_id: ^user_id))

  defp scoped(scope) do
    case split(scope) do
      {plugin_id, nil} -> where(StoredValue, [v], v.plugin_id == ^plugin_id and is_nil(v.user_id))
      {plugin_id, user_id} -> where(StoredValue, plugin_id: ^plugin_id, user_id: ^user_id)
    end
  end

  defp split({plugin_id, user_id}) when is_binary(plugin_id) and is_integer(user_id),
    do: {plugin_id, user_id}

  defp split(plugin_id) when is_binary(plugin_id), do: {plugin_id, nil}
end
