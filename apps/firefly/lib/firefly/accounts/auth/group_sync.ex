defmodule Firefly.Accounts.Auth.GroupSync do
  @moduledoc """
  Group membership kept in step with a single sign-on provider (see
  `Firefly.Accounts.Auth.DiscourseConnect` and `Firefly.Accounts.Auth.SAML`):
  only groups that exist here are joined, except the staff groups (admin,
  moderator), which are created when first granted. Every change goes to
  the staff log as the system's.
  """

  import Ecto.Query

  alias Firefly.{Groups, Repo}
  alias Firefly.Groups.{Role, RoleMembership}
  alias Firefly.Moderation.StaffLog

  @staff_groups ~w(admin moderator)

  @doc "The staff groups, which `mirror/2` leaves alone."
  def staff_groups, do: @staff_groups

  @doc """
  Makes `user`'s groups, staff groups aside, exactly those of `names` that
  exist here.
  """
  def mirror(user, names) do
    names = Enum.reject(names, &(&1 in @staff_groups))

    unlisted =
      Repo.all(
        from(r in Role,
          join: m in RoleMembership,
          on: m.role_id == r.id and m.user_id == ^user.id,
          where: r.name not in ^(@staff_groups ++ names),
          select: r.name
        )
      )

    for name <- unlisted, do: set_member(user, name, false)
    for name <- names, do: set_member(user, name, true)
    :ok
  end

  @doc "Adds `user` to the group `name`, or removes them (`member?` false)."
  def set_member(user, name, member?) do
    role =
      Repo.get_by(Role, name: name) ||
        if(member? and name in @staff_groups, do: elem(Groups.create_role(name), 1))

    if role, do: set_membership(user, role, member?)
  end

  defp set_membership(user, role, member?) do
    membership =
      Repo.one(from(m in RoleMembership, where: m.role_id == ^role.id and m.user_id == ^user.id))

    details = %{role: role.name, username: user.username}

    cond do
      member? and is_nil(membership) ->
        {:ok, _} = Groups.add_role(user, role)
        StaffLog.record_system("role.grant", user, details)

      not member? and membership != nil ->
        Repo.delete!(membership)
        StaffLog.record_system("role.revoke", user, details)

      true ->
        :ok
    end
  end
end
