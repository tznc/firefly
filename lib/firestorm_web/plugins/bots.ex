defmodule FirestormWeb.Plugins.Bots do
  @moduledoc """
  Each plugin acts as its own bot user (`plugin_bot` set to the plugin's
  id): its replies, flags, tags and moderation show who did them, and go
  through the same contexts and policies as anyone's. Uploaded plugins get
  theirs on install; core plugins on first use. The bot can't log in (no
  password, no GitHub account) and outlives an uninstall, keeping its posts.
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Repo}
  alias FirestormWeb.Forums.User

  @doc "`plugin`'s bot user, created if needed (`plugin` a manifest or plugin)."
  def ensure(%{id: id, name: name}), do: ensure(id, name)
  def ensure(%{id: id, manifest: %{name: name}}), do: ensure(id, name)

  def ensure(id, name) do
    case Repo.one(from(u in User, where: u.plugin_bot == ^id)) do
      %User{} = bot -> bot
      nil -> create(id, name)
    end
  end

  defp create(id, name) do
    {:ok, bot} =
      Repo.transact(fn ->
        {:ok, user} =
          Forums.create_user(%{
            username: free_username("#{id}-bot"),
            name: String.slice("#{name} (bot)", 0, 100)
          })

        {:ok, Repo.update!(Ecto.Changeset.change(user, plugin_bot: id))}
      end)

    bot
  end

  # A member may already have the name.
  defp free_username(base) do
    Enum.find(Stream.concat([base], Stream.map(2..1000, &"#{base}#{&1}")), fn name ->
      not Repo.exists?(from(u in User, where: u.username == ^name))
    end)
  end

  @doc "The plugin id `user` acts for, or nil."
  def plugin_of(%User{plugin_bot: id}), do: id
  def plugin_of(_user), do: nil
end
