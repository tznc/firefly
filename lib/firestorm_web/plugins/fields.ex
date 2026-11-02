defmodule FirestormWeb.Plugins.Fields do
  @moduledoc """
  Plugins' custom fields on posts, threads and users: values a plugin keeps
  about forum records, namespaced by plugin (host functions `fields.get`
  and `fields.set`, the `fields` permission). A plugin can only set the
  fields its manifest declares (`fields: [{type, key, public}]`) and only
  sees its own. Values are any JSON, at most 10 KB; nil removes a field.

  Fields declared `public` are exposed in the JSON API, under each post's
  `plugin_fields` (by plugin id, then key), while the plugin is active.
  Uninstalling a plugin deletes its fields.
  """

  import Ecto.Query

  alias FirestormWeb.{Plugins, Repo}
  alias FirestormWeb.Plugins.Field

  @types ~w(post thread user)
  @max_size 10 * 1024

  @doc "`plugin_id`'s fields on the `type` record `id`, by key."
  def get(plugin_id, type, id) when type in @types do
    Field
    |> where([f], f.plugin_id == ^plugin_id and f.target_type == ^type and f.target_id == ^id)
    |> select([f], {f.key, f.value})
    |> Repo.all()
    |> Map.new(fn {key, %{"v" => value}} -> {key, value} end)
  end

  @doc """
  Sets the field `key` of `plugin` on the `type` record `id`: `:ok` or
  `{:error, message}` if the manifest doesn't declare it or it's too big.
  """
  def put(plugin, type, id, key, value) do
    declared = Enum.any?(plugin.manifest.fields, &(&1["type"] == type and &1["key"] == key))

    cond do
      not declared ->
        {:error, "#{type} field #{key} isn't declared in the manifest"}

      is_nil(value) ->
        Repo.delete_all(
          where(Field, plugin_id: ^plugin.id, target_type: ^type, target_id: ^id, key: ^key)
        )

        :ok

      byte_size(Jason.encode!(value)) > @max_size ->
        {:error, "field values must be at most 10 KB"}

      true ->
        Repo.insert!(
          %Field{
            plugin_id: plugin.id,
            target_type: type,
            target_id: id,
            key: key,
            value: %{"v" => value}
          },
          on_conflict: [set: [value: %{"v" => value}, updated_at: NaiveDateTime.utc_now()]],
          conflict_target: [:plugin_id, :target_type, :target_id, :key]
        )

        :ok
    end
  end

  @doc """
  The active plugins' public fields on the `type` records `ids`:
  `%{id => %{plugin_id => %{key => value}}}`.
  """
  def public(type, ids) when type in @types do
    declared =
      for plugin <- Plugins.active(),
          field <- plugin.manifest.fields,
          field["type"] == type and field["public"] == true,
          do: {plugin.id, field["key"]}

    if declared == [] or ids == [] do
      %{}
    else
      Field
      |> where([f], f.target_type == ^type and f.target_id in ^ids)
      |> Repo.all()
      |> Enum.filter(&({&1.plugin_id, &1.key} in declared))
      |> Enum.reduce(%{}, fn field, acc ->
        put_in(
          acc,
          [Access.key(field.target_id, %{}), Access.key(field.plugin_id, %{}), field.key],
          field.value["v"]
        )
      end)
    end
  end

  @doc "Deletes `plugin_id`'s fields (on uninstall)."
  def clear(plugin_id), do: Repo.delete_all(where(Field, plugin_id: ^plugin_id))
end
