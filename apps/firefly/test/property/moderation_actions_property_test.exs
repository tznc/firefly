defmodule Firefly.ModerationActionsPropertyTest do
  @moduledoc """
  Properties of staff actions in `Firefly.Moderation`: penalizing with
  parameters of any shape (the API passes them through) is a penalty in
  force or a reason, never a crash, and lifting ends it; a thread's timer
  matches a model of setting, cancelling and running timers; and flags
  hide a post exactly when the `flags_to_hide` setting's count of members
  have flagged it, never an admin's.
  """
  # Sync: it makes admins (the shared admin role) and sends mail.
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.{Accounts, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Post, Thread}
  alias Firefly.Moderation.{Flags, Penalties, TopicTimers}

  defp member(trust_level \\ 1) do
    {:ok, user} = Accounts.confirm_user(user_fixture())
    Repo.update!(Ecto.Changeset.change(user, trust_level: trust_level))
  end

  defp first_post(thread),
    do: Repo.one!(from(p in Post, where: p.thread_id == ^thread.id, order_by: p.id, limit: 1))

  describe "penalties" do
    defp param,
      do: one_of([json_value(), adversarial_text(2), member_of(Firefly.Generators.numbers())])

    defp until_date do
      one_of([
        map(integer(-400..4000), &(Date.utc_today() |> Date.add(&1) |> Date.to_iso8601())),
        param()
      ])
    end

    property "any parameters give a penalty in force or a reason; lifting ends it" do
      admin = admin_fixture()

      check all(
              kind <- member_of([:silence, :suspend]),
              params <-
                optional_map(%{
                  "duration" => one_of([member_of(~w(1d 1w 1m date forever)), param()]),
                  "until" => until_date(),
                  "reason" => one_of([constant("Spam."), param()])
                }),
              max_runs: runs(150)
            ) do
        user = member()
        in_force? = if kind == :silence, do: &User.silenced?/1, else: &User.suspended?/1

        case Penalties.penalize(kind, user, admin, params) do
          {:ok, penalized} ->
            assert in_force?.(penalized)
            assert in_force?.(Repo.get!(User, user.id))
            {:ok, lifted} = Penalties.lift(kind, penalized, admin)
            refute in_force?.(lifted)

          {:error, reason} ->
            assert is_binary(Penalties.message(reason))
            refute in_force?.(Repo.get!(User, user.id))
        end
      end
    end
  end

  describe "thread timers" do
    defp timer_command do
      one_of([
        tuple({constant(:set), member_of(~w(close open delete)), integer(1..60)}),
        constant(:cancel),
        tuple({constant(:run), integer(0..90)})
      ])
    end

    test "a thread's timer matches a model of setting, cancelling and running" do
      admin = admin_fixture()
      category = category_fixture("Timers")

      check all(commands <- list_of(timer_command(), max_length: 10), max_runs: runs(40)) do
        thread = thread_fixture(category, admin)
        # Minutes count from here; timers are whole seconds.
        base = DateTime.utc_now(:second) |> DateTime.add(1, :second)
        at = &DateTime.add(base, &1, :minute)

        Enum.reduce_while(commands, %{timer: nil, closed: false}, fn command, model ->
          current = Repo.get!(Thread, thread.id)

          model =
            case command do
              {:set, action, minutes} ->
                {:ok, _} =
                  TopicTimers.set_timer(current, %{action: action, run_at: at.(minutes)}, admin)

                %{model | timer: {action, minutes}}

              :cancel ->
                :ok = TopicTimers.cancel_timer(current, admin)
                %{model | timer: nil}

              {:run, minutes} ->
                TopicTimers.run_due(at.(minutes))

                case model.timer do
                  {"delete", due} when due <= minutes -> :deleted
                  {"close", due} when due <= minutes -> %{model | timer: nil, closed: true}
                  {"open", due} when due <= minutes -> %{model | timer: nil, closed: false}
                  _not_due -> model
                end
            end

          case model do
            :deleted ->
              assert Repo.get(Thread, thread.id) == nil
              {:halt, model}

            model ->
              thread = Repo.get!(Thread, thread.id)
              assert not is_nil(thread.closed_at) == model.closed

              case {model.timer, TopicTimers.get_timer(thread)} do
                {nil, timer} -> assert timer == nil
                {{action, m}, timer} -> assert {timer.action, timer.run_at} == {action, at.(m)}
              end

              {:cont, model}
          end
        end)
      end
    end
  end

  describe "flags" do
    test "a post is hidden exactly when enough members flagged it, never an admin's" do
      admin = admin_fixture()
      flaggers = for _ <- 1..4, do: member()
      category = category_fixture("Flags")

      check all(
              threshold <- integer(1..4),
              flags <- list_of(integer(0..3), max_length: 6),
              by_admin? <- boolean(),
              max_runs: runs(30)
            ) do
        {:ok, _} = SiteSettings.update(%{"flags_to_hide" => to_string(threshold)}, admin)
        author = if by_admin?, do: admin, else: member()
        post = category |> thread_fixture(author) |> first_post()

        flagged =
          Enum.reduce(flags, MapSet.new(), fn i, flagged ->
            result = Flags.flag_post(post, Enum.at(flaggers, i), %{reason: "spam"})

            if i in flagged do
              assert {:error, :already_flagged} = result
              flagged
            else
              assert {:ok, _} = result
              MapSet.put(flagged, i)
            end
          end)

        hidden? = not is_nil(Repo.get!(Post, post.id).hidden_at)
        assert hidden? == (not by_admin? and MapSet.size(flagged) >= threshold)
        assert {:error, :unauthorized} = Flags.flag_post(post, author, %{reason: "spam"})
      end
    end
  end
end
