defmodule FirestormWeb.Emoji do
  @moduledoc """
  Emoji: the standard set (gemoji's names, as MDEx's `:shortcode:`
  extension renders them; the editor's picker and `:` autocomplete load
  the same list from `priv/static/vendor/emoji.json`) and custom emoji
  admins add at `/staff/emoji`.

  A custom emoji is an image uploaded through `FirestormWeb.Uploads` (the
  `"emoji"` variant: scaled to fit 128 pixels, public) with a name;
  `:name:` in a post renders it as `<img class="emoji">` (see
  `FirestormWeb.Markdown`). Adding and removing them is recorded in the
  staff log.

  The name-to-image map is read on every render, so it's kept in
  `:persistent_term`: loaded at start (see `FirestormWeb.SiteSettings.Cache`)
  and reloaded on every node when an emoji changes.
  """

  import Ecto.Query

  alias FirestormWeb.{Repo, SiteSettings, StaffLog, Uploads}
  alias FirestormWeb.Emoji.CustomEmoji
  alias FirestormWeb.Forums.User

  @standard_path "priv/static/vendor/emoji.json"
  @external_resource @standard_path
  @standard @standard_path
            |> File.read!()
            |> Jason.decode!()
            |> Map.fetch!("emoji")
            |> Enum.flat_map(fn [_emoji, names | _] -> names end)
            |> MapSet.new()

  @cache_key {__MODULE__, :custom}

  @doc "Whether `name` is a standard emoji's (e.g. `smile`)."
  def standard?(name), do: MapSet.member?(@standard, name)

  @doc "Custom emoji, by name: `%{name => image URL}`."
  def custom do
    case :persistent_term.get(@cache_key, nil) do
      nil -> reload()
      custom -> custom
    end
  end

  @doc "Loads the custom emoji into this node's cache. Returns them."
  def reload do
    custom =
      CustomEmoji
      |> preload(:upload)
      |> Repo.all()
      |> Map.new(&{&1.name, Uploads.url(&1.upload)})

    put_cache(custom)
    custom
  end

  @doc false
  def put_cache(custom), do: :persistent_term.put(@cache_key, custom)

  # This node reloads at once; the others when they hear of it.
  defp changed do
    reload()
    Phoenix.PubSub.broadcast(FirestormWeb.PubSub, SiteSettings.topic(), {:emoji_changed, node()})
  end

  @doc "Custom emoji, by name, with their images."
  def list do
    CustomEmoji
    |> order_by(:name)
    |> preload([:upload, :created_by])
    |> Repo.all()
  end

  @doc "The custom emoji `user` added, for the account export."
  def export(%User{id: user_id}) do
    CustomEmoji
    |> where([e], e.created_by_id == ^user_id)
    |> order_by(:id)
    |> select([e], %{name: e.name, added_at: e.inserted_at})
    |> Repo.all()
  end

  @doc "A changeset for the add form."
  def change_emoji(attrs \\ %{}), do: CustomEmoji.changeset(%CustomEmoji{}, attrs)

  @doc """
  Adds a custom emoji named `attrs["name"]` from the image at `path`, as
  `admin`. Returns `{:ok, emoji}`, `{:error, changeset}` or
  `{:error, message}` (the image was refused).
  """
  def create(%User{} = admin, attrs, path, filename) do
    changeset = change_emoji(attrs)

    with {:ok, _valid} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, upload} <- upload(admin, path, filename) do
      changeset
      |> Ecto.Changeset.put_change(:upload_id, upload.id)
      |> Ecto.Changeset.put_change(:created_by_id, admin.id)
      |> insert(admin, upload)
    end
  end

  defp upload(admin, path, filename) do
    case Uploads.create(admin, path, filename, variant: "emoji") do
      {:error, :rate_limited} -> {:error, FirestormWeb.RateLimit.message()}
      result -> result
    end
  end

  defp insert(changeset, admin, upload) do
    result =
      Repo.transact(fn ->
        with {:ok, emoji} <- Repo.insert(changeset) do
          StaffLog.record(admin, "emoji.create", {"emoji", emoji.id}, %{name: emoji.name})
          {:ok, emoji}
        end
      end)

    case result do
      {:ok, emoji} ->
        changed()
        {:ok, %{emoji | upload: upload}}

      {:error, changeset} ->
        # The name was taken meanwhile: the image isn't needed.
        Uploads.remove(upload)
        {:error, changeset}
    end
  end

  @doc "Removes a custom emoji and its image, as `admin`."
  def delete(%CustomEmoji{} = emoji, %User{} = admin) do
    emoji = Repo.preload(emoji, :upload)

    {:ok, _} =
      Repo.transact(fn ->
        Repo.delete!(emoji)
        StaffLog.record(admin, "emoji.delete", {"emoji", emoji.id}, %{name: emoji.name})
        {:ok, emoji}
      end)

    Uploads.remove(emoji.upload)
    changed()
    :ok
  end

  @doc "For `FirestormWeb.Uploads`: an emoji's image was deleted, and the emoji with it."
  def image_deleted, do: changed()
end
