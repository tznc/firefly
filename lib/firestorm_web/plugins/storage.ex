defmodule FirestormWeb.Plugins.Storage do
  @moduledoc """
  Each plugin's own key-value storage (host functions `kv.get`, `kv.set`,
  `kv.delete`, `kv.list`). Values are any JSON. Keys are 1-200 characters.
  Quotas per plugin (`config :firestorm_web, FirestormWeb.Plugins.Storage`):
  `:max_keys` (1,000) and `:max_bytes` (1 MB of encoded values). A plugin
  only ever sees its own keys; uninstalling it deletes them.
  """

  import Ecto.Query

  alias FirestormWeb.Repo
  alias FirestormWeb.Plugins.StoredValue

  @doc "The value under `key`, or nil."
  def get(plugin_id, key) do
    case Repo.get_by(StoredValue, plugin_id: plugin_id, key: key) do
      %StoredValue{value: %{"v" => value}} -> value
      nil -> nil
    end
  end

  @doc "Stores `value` under `key`: `:ok` or `{:error, message}` (bad key, over quota)."
  def put(plugin_id, key, value) do
    size = byte_size(Jason.encode!(value))

    with :ok <- check_key(key),
         {:ok, :stored} <- store(plugin_id, key, value, size),
         do: :ok
  end

  defp store(plugin_id, key, value, size) do
    Repo.transact(fn ->
      # Serializes a plugin's writes, so two can't both squeeze under the quota.
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["plugin_kv:" <> plugin_id])
      existing = Repo.get_by(StoredValue, plugin_id: plugin_id, key: key)

      with :ok <- check_quota(plugin_id, existing, size) do
        row = existing || %StoredValue{plugin_id: plugin_id, key: key}
        Repo.insert_or_update!(Ecto.Changeset.change(row, value: %{"v" => value}, size: size))
        {:ok, :stored}
      end
    end)
  end

  defp check_key(key) do
    if is_binary(key) and String.length(key) in 1..200,
      do: :ok,
      else: {:error, "keys must be text of 1 to 200 characters"}
  end

  defp check_quota(plugin_id, existing, size) do
    {count, bytes} =
      Repo.one(
        from(v in StoredValue,
          where: v.plugin_id == ^plugin_id,
          select: {count(v.id), coalesce(sum(v.size), 0)}
        )
      )

    {count, bytes} = if existing, do: {count - 1, bytes - existing.size}, else: {count, bytes}

    cond do
      count + 1 > quota(:max_keys, 1_000) ->
        {:error, "storage quota exceeded: too many keys"}

      bytes + size > quota(:max_bytes, 1_048_576) ->
        {:error, "storage quota exceeded: too much data"}

      true ->
        :ok
    end
  end

  defp quota(key, default),
    do: Application.get_env(:firestorm_web, __MODULE__, [])[key] || default

  @doc "Deletes `key`."
  def delete(plugin_id, key) do
    Repo.delete_all(where(StoredValue, plugin_id: ^plugin_id, key: ^key))
    :ok
  end

  @doc "The keys starting with `prefix`, sorted, at most 1,000."
  def list(plugin_id, prefix \\ "") do
    StoredValue
    |> where([v], v.plugin_id == ^plugin_id and like(v.key, ^(escape_like(prefix) <> "%")))
    |> order_by(:key)
    |> limit(1_000)
    |> select([v], v.key)
    |> Repo.all()
  end

  defp escape_like(prefix), do: String.replace(prefix, ~r/([\\%_])/, "\\\\\\1")

  @doc "How much `plugin_id` stores: `%{keys, bytes}`."
  def usage(plugin_id) do
    {keys, bytes} =
      Repo.one(
        from(v in StoredValue,
          where: v.plugin_id == ^plugin_id,
          select: {count(v.id), coalesce(sum(v.size), 0)}
        )
      )

    %{keys: keys, bytes: bytes}
  end

  @doc "Deletes everything `plugin_id` stored (on uninstall)."
  def clear(plugin_id), do: Repo.delete_all(where(StoredValue, plugin_id: ^plugin_id))
end
