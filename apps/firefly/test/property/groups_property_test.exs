defmodule Firefly.GroupsPropertyTest do
  @moduledoc """
  Properties of `Firefly.Groups`, for every combination of a group's
  settings and who's asking (a visitor, an outsider, a member, an owner,
  an admin): who sees it (the one-group rule and the list query agree),
  who may mention and message it, and what joining does, all as a model
  table says; and managing members never crashes on any username.
  """
  # Sync: it makes admins (the shared admin role).
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.Groups
  alias Firefly.Groups.Role

  @kinds [:visitor, :outsider, :member, :owner, :admin]

  defp settings do
    fixed_map(%{
      visibility: member_of(Role.visibilities()),
      membership: member_of(Role.memberships()),
      mentionable: member_of(Role.levels()),
      messageable: member_of(Role.levels())
    })
  end

  # The model.
  defp visible?(%{visibility: "public"}, _kind), do: true
  defp visible?(%{visibility: "members"}, kind), do: kind in [:member, :owner, :admin]
  defp visible?(_settings, kind), do: kind == :admin

  defp allowed?(_level, :visitor), do: false
  defp allowed?(_level, :admin), do: true
  defp allowed?("everyone", _kind), do: true
  defp allowed?("members", kind), do: kind in [:member, :owner]
  defp allowed?("owners", kind), do: kind == :owner
  defp allowed?("nobody", _kind), do: false

  defp join_result(settings, kind) do
    cond do
      not visible?(settings, kind) -> {:error, :closed}
      kind in [:member, :owner] -> {:error, :already_member}
      settings.membership == "open" -> {:ok, :joined}
      settings.membership == "request" -> {:ok, :requested}
      true -> {:error, :closed}
    end
  end

  test "visibility, mentioning, messaging and joining follow the settings, for everyone" do
    admin = admin_fixture()

    check all(settings <- settings(), max_runs: runs(40)) do
      {:ok, group} = Groups.create_group(%{name: "g#{System.unique_integer([:positive])}"}, admin)
      {:ok, group} = Groups.update_settings(group, settings, admin)

      [outsider, member, owner] = for _ <- 1..3, do: user_fixture()
      {:ok, _} = Groups.add_member(group, member.username, admin)
      {:ok, _} = Groups.add_member(group, owner.username, admin)
      {:ok, _} = Groups.set_owner(group, owner, true, admin)

      people = %{visitor: nil, outsider: outsider, member: member, owner: owner, admin: admin}

      for kind <- @kinds, viewer = people[kind] do
        assert Groups.visible?(group, viewer) == visible?(settings, kind),
               "#{kind} sees #{inspect(settings)}"

        listed? =
          viewer |> Groups.list_visible() |> Enum.any?(fn {g, _count} -> g.id == group.id end)

        assert listed? == visible?(settings, kind), "#{kind}'s list for #{inspect(settings)}"

        assert Groups.can_mention?(group, viewer) == allowed?(settings.mentionable, kind)
        assert Groups.can_message?(group, viewer) == allowed?(settings.messageable, kind)
      end

      # A visitor can't join; everyone else as the model says, once.
      for kind <- [:outsider, :member, :owner] do
        user = people[kind]
        expected = join_result(settings, kind)
        assert Groups.join(group, user) == expected, "#{kind} joining #{inspect(settings)}"

        case expected do
          {:ok, :joined} ->
            assert Groups.member?(group, user)
            assert Groups.join(group, user) == {:error, :already_member}

          {:ok, :requested} ->
            refute Groups.member?(group, user)
            assert Groups.join(group, user) == {:error, :already_requested}

          {:error, _} ->
            :ok
        end
      end
    end
  end

  property "managing members never crashes on any username" do
    admin = admin_fixture()
    {:ok, group} = Groups.create_group(%{name: "g#{System.unique_integer([:positive])}"}, admin)

    check all(name <- one_of([adversarial_text(5), any_text(), username()]), max_runs: runs(80)) do
      for result <- [Groups.add_member(group, name, admin), Groups.invite(group, name, admin)] do
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end

      assert is_map(Groups.by_names([name]))
    end
  end
end
