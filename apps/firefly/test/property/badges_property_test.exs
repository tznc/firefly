defmodule Firefly.BadgesPropertyTest do
  @moduledoc """
  Properties of `Firefly.Badges`: granting what's earned is idempotent and
  never grants a single badge twice; trust level badges follow the level
  reached (and stay after a demotion, as in Discourse); and any sequence
  of admin grants, revokes and title changes leaves holdings and titles
  as a model says.
  """
  # Sync: it makes admins (the shared admin role) and grants to everyone.
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.{Badges, Repo, TrustLevels}
  alias Firefly.Accounts.User
  alias Firefly.Badges.Badge

  @trust_badges %{1 => "Basic User", 2 => "Member", 3 => "Regular", 4 => "Leader"}

  defp held_names(user),
    do: user |> Badges.user_badges() |> Enum.map(fn {badge, _count, _at} -> badge.name end)

  defp grant_counts do
    Repo.all(
      from(ub in "user_badges",
        join: b in Badge,
        on: b.id == ub.badge_id,
        where: not b.multiple_grant,
        group_by: [ub.badge_id, ub.user_id],
        select: count()
      )
    )
  end

  test "trust level badges follow the highest level reached; granting again grants nothing" do
    admin = admin_fixture()

    check all(levels <- list_of(integer(0..4), min_length: 1, max_length: 4), max_runs: runs(20)) do
      user = user_fixture(%{trust_level: 0})

      highest =
        Enum.reduce(levels, 0, fn level, highest ->
          {:ok, _} = TrustLevels.set_level(Repo.get!(User, user.id), level, false, admin)
          max(highest, level)
        end)

      Badges.grant_earned(nil)
      held = held_names(user)

      for {level, name} <- @trust_badges do
        assert name in held == level <= highest, "#{name} after levels #{inspect(levels)}"
      end

      before = Repo.aggregate("user_badges", :count)
      Badges.grant_earned(nil)
      assert Repo.aggregate("user_badges", :count) == before
      assert Enum.all?(grant_counts(), &(&1 == 1))
    end
  end

  defp command do
    one_of([
      tuple({constant(:grant), integer(0..2), one_of([constant(nil), adversarial_text(3)])}),
      tuple({constant(:revoke), integer(0..5)}),
      tuple(
        {constant(:title),
         one_of([integer(0..2), constant(nil), member_of(["", "x", "1x", "-1"])])}
      )
    ])
  end

  test "grants, revokes and titles follow the model" do
    admin = admin_fixture()

    check all(
            specs <- list_of({boolean(), boolean(), boolean()}, length: 3),
            commands <- list_of(command(), min_length: 1, max_length: 12),
            max_runs: runs(25)
          ) do
      user = user_fixture()

      badges =
        for {{multiple?, title?, enabled?}, n} <- Enum.with_index(specs) do
          {:ok, badge} =
            Badges.create_badge(
              %{
                name: "B#{n} #{System.unique_integer([:positive])}",
                multiple_grant: multiple?,
                allow_title: title?
              },
              admin
            )

          if enabled?,
            do: badge,
            else: elem(Badges.update_badge(badge, %{enabled: false}, admin), 1)
        end

      # The model: grants (badge index per grant, in order) and the title.
      Enum.reduce(commands, %{grants: [], title: nil}, fn command, model ->
        model = step(command, model, badges, user, admin)

        holdings = Enum.frequencies(model.grants)

        held =
          Repo.all(from(ub in "user_badges", where: ub.user_id == ^user.id, select: ub.badge_id))

        assert Enum.frequencies(
                 Enum.map(held, fn id -> Enum.find_index(badges, &(&1.id == id)) end)
               ) == holdings

        title_id = Repo.get!(User, user.id).title_badge_id
        assert title_id == (model.title && Enum.at(badges, model.title).id)
        model
      end)
    end
  end

  defp step({:grant, b, reason}, model, badges, user, admin) do
    badge = Enum.at(badges, b)
    result = Badges.grant(badge, user, admin, reason)

    cond do
      not badge.enabled ->
        assert result == {:error, :disabled}
        model

      # By hand there's no post: a multiple badge too is granted once.
      b in model.grants ->
        assert result == {:error, :already_granted}
        model

      true ->
        assert {:ok, _} = result
        %{model | grants: model.grants ++ [b]}
    end
  end

  defp step({:revoke, i}, model, badges, user, admin) do
    grants =
      Repo.all(
        from(ub in "user_badges",
          where: ub.user_id == ^user.id,
          order_by: ub.id,
          select: {ub.id, ub.badge_id}
        )
      )

    case Enum.at(grants, i) do
      nil ->
        assert Badges.revoke(-1, admin) == {:error, :not_found}
        model

      {id, badge_id} ->
        assert {:ok, _} = Badges.revoke(id, admin)
        b = Enum.find_index(badges, &(&1.id == badge_id))
        grants = List.delete(model.grants, b)
        # The title goes with the last grant of its badge.
        title = if model.title == b and b not in grants, do: nil, else: model.title
        %{model | grants: grants, title: title}
    end
  end

  defp step({:title, choice}, model, badges, user, _admin) do
    user = Repo.get!(User, user.id)

    {arg, expected_ok, new_title} =
      case choice do
        b when is_integer(b) ->
          badge = Enum.at(badges, b)
          ok? = b in model.grants and badge.allow_title and badge.enabled
          {badge.id, ok?, if(ok?, do: b, else: model.title)}

        blank when blank in [nil, ""] ->
          {blank, true, nil}

        junk ->
          {junk, false, model.title}
      end

    result = Badges.set_title(user, arg)

    assert match?({:ok, _}, result) == expected_ok,
           "set_title(#{inspect(arg)}): #{inspect(result)}"

    %{model | title: new_title}
  end
end
