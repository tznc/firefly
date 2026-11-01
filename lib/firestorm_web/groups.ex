defmodule FirestormWeb.Groups do
  @moduledoc """
  Groups are roles (`FirestormWeb.Forums.Role`): admins create them and
  manage their members at `/staff/groups` (or in the Kaffy admin), and can
  restrict categories to them (see `FirestormWeb.Forums.Policy`). Every
  change goes to the staff log, in the same transaction.
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Repo, StaffLog}
  alias FirestormWeb.Forums.{Role, RoleMembership, User}

  @doc "Every group by name, with its members (by username) and restricted categories."
  def list_groups do
    members = from(u in User, order_by: u.username)

    Role
    |> order_by(:name)
    |> preload(users: ^members)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :categories, categories(&1)))
  end

  defp categories(%Role{id: role_id}) do
    Repo.all(
      from(c in Forums.Category,
        join: cr in "forums_category_roles",
        on: cr.category_id == c.id,
        where: cr.role_id == ^role_id,
        order_by: c.title
      )
    )
  end

  @doc "Gets a group by id. Raises `Ecto.NoResultsError` if there's none."
  def get_group!(id), do: Repo.get!(Role, id)

  def change_group(attrs \\ %{}), do: Role.changeset(%Role{}, attrs)

  @doc "Creates a group (a role) as `actor`."
  def create_group(attrs, %User{} = actor) do
    Repo.transact(fn ->
      with {:ok, role} <- %Role{} |> Role.changeset(attrs) |> Repo.insert() do
        StaffLog.record(actor, "role.create", {"role", role.id}, %{role: role.name})
        {:ok, role}
      end
    end)
  end

  @doc """
  Adds the user named `username` to the group, as `actor`. Errors:
  `:no_such_user`, `:already_member`.
  """
  def add_member(%Role{} = role, username, %User{} = actor) do
    name = username |> to_string() |> String.trim() |> String.trim_leading("@")

    case [String.downcase(name)] |> Forums.users_by_username() |> Map.values() do
      [] ->
        {:error, :no_such_user}

      [user] ->
        if member?(role, user), do: {:error, :already_member}, else: grant(role, user, actor)
    end
  end

  defp grant(role, user, actor) do
    Repo.transact(fn ->
      {:ok, _} = Forums.add_role(user, role)
      StaffLog.record(actor, "role.grant", user, %{role: role.name, username: user.username})
      {:ok, user}
    end)
  end

  @doc """
  Removes `user` from the group, as `actor`. Admins can't take themselves
  out of "admin" (`{:error, :own_admin}`): someone else has to.
  """
  def remove_member(%Role{name: "admin"}, %User{id: id}, %User{id: id}),
    do: {:error, :own_admin}

  def remove_member(%Role{} = role, %User{} = user, %User{} = actor) do
    Repo.transact(fn ->
      {count, _} =
        RoleMembership
        |> where([m], m.role_id == ^role.id and m.user_id == ^user.id)
        |> Repo.delete_all()

      if count > 0,
        do:
          StaffLog.record(actor, "role.revoke", user, %{role: role.name, username: user.username})

      {:ok, user}
    end)
  end

  defp member?(role, user) do
    Repo.exists?(
      from(m in RoleMembership, where: m.role_id == ^role.id and m.user_id == ^user.id)
    )
  end

  @doc "A message for an error from this module."
  def message(:no_such_user), do: "No user with that username."
  def message(:already_member), do: "They're already in that group."
  def message(:own_admin), do: "You can't remove yourself from the admins."
end
