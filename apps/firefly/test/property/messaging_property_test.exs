defmodule Firefly.MessagingPropertyTest do
  @moduledoc """
  Properties of `Firefly.Messaging` and the group inboxes it shares with
  `Firefly.Groups`, checked against a model through random sequences of
  conversations, replies, leaving, reading and group membership changes:
  who may read and reply (`:view_conversation`) is always the model's
  answer (active participants, and the group's members), replies succeed
  exactly for them, inboxes hold exactly the conversations a user is in,
  and unread counts are what was posted since the last read.
  """
  # Sync: it makes admins (the shared admin role) and runs long.
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.{Groups, Messaging}
  alias Firefly.Messaging.Conversation

  @people 3

  defp can_read?(user, conversation),
    do: Bodyguard.permit?(Firefly.Discussion, :view_conversation, user, conversation)

  defp command do
    frequency([
      {2,
       tuple(
         {constant(:start), integer(0..2), list_of(integer(0..2), min_length: 1, max_length: 3),
          boolean()}
       )},
      {3, tuple({constant(:reply), integer(0..2), integer(0..2)})},
      {2, tuple({constant(:leave), integer(0..2), integer(0..2)})},
      {1, tuple({constant(:read), integer(0..2), integer(0..2)})},
      {2, tuple({constant(:join_group), integer(0..2)})},
      {1, tuple({constant(:leave_group), integer(0..2)})}
    ])
  end

  # The model: conversations (in order) with their group flag, each
  # person's state in it (:active or :left) and its message count; each
  # person's read position (messages read) per conversation; the group's
  # members.
  defp reader?(model, c, p),
    do:
      Map.get(Enum.at(model.convs, c).people, p) == :active or
        (Enum.at(model.convs, c).group? and p in model.members)

  defp step({:start, sender, recipients, group?}, model, world) do
    names =
      recipients
      |> Enum.reject(&(&1 == sender))
      |> Enum.uniq()
      |> Enum.map(&Enum.at(world.users, &1).username)

    names = if group?, do: [world.group.name | names], else: names

    attrs = %{
      "title" => "Plans #{System.unique_integer([:positive])}",
      "body" => "Hello there.",
      "recipients" => Enum.join(names, ", ")
    }

    case Messaging.start_conversation(Enum.at(world.users, sender), attrs) do
      {:ok, conversation} ->
        assert names != []

        people =
          Map.new([sender | Enum.reject(Enum.uniq(recipients), &(&1 == sender))], &{&1, :active})

        conv = %{
          id: conversation.id,
          group?: group?,
          people: people,
          messages: 1,
          read: %{sender => 1}
        }

        %{model | convs: model.convs ++ [conv]}

      {:error, _changeset} ->
        # Only when there's nobody to send to.
        assert names == []
        model
    end
  end

  defp step({:reply, c, p}, %{convs: convs} = model, world) when convs != [] do
    c = rem(c, length(convs))
    conv = Enum.at(convs, c)
    allowed? = reader?(model, c, p)

    result =
      Messaging.reply(Repo.get!(Conversation, conv.id), Enum.at(world.users, p), %{
        "body" => "A reply here."
      })

    if allowed? do
      assert {:ok, _message} = result,
             "person #{p} may reply to #{inspect(conv)}: #{inspect(result)}"

      conv = %{conv | messages: conv.messages + 1, people: Map.put(conv.people, p, :active)}
      conv = %{conv | read: Map.put(conv.read, p, conv.messages)}
      %{model | convs: List.replace_at(convs, c, conv)}
    else
      assert {:error, :unauthorized} = result
      model
    end
  end

  defp step({:leave, c, p}, %{convs: convs} = model, world) when convs != [] do
    c = rem(c, length(convs))
    conv = Enum.at(convs, c)
    :ok = Messaging.leave(Repo.get!(Conversation, conv.id), Enum.at(world.users, p))

    people =
      if Map.has_key?(conv.people, p), do: Map.put(conv.people, p, :left), else: conv.people

    %{model | convs: List.replace_at(convs, c, %{conv | people: people})}
  end

  defp step({:read, c, p}, %{convs: convs} = model, world) when convs != [] do
    c = rem(c, length(convs))
    conv = Enum.at(convs, c)
    :ok = Messaging.mark_read(Repo.get!(Conversation, conv.id), Enum.at(world.users, p))

    read =
      if Map.has_key?(conv.people, p), do: Map.put(conv.read, p, conv.messages), else: conv.read

    %{model | convs: List.replace_at(convs, c, %{conv | read: read})}
  end

  defp step({:join_group, p}, model, world) do
    user = Enum.at(world.users, p)

    case Groups.add_member(world.group, user.username, world.admin) do
      {:ok, _} -> assert p not in model.members
      {:error, :already_member} -> assert p in model.members
    end

    %{model | members: MapSet.put(model.members, p)}
  end

  defp step({:leave_group, p}, model, world) do
    {:ok, _} = Groups.remove_member(world.group, Enum.at(world.users, p), world.admin)
    %{model | members: MapSet.delete(model.members, p)}
  end

  # Commands on conversations before there are any do nothing.
  defp step(_command, model, _world), do: model

  defp assert_matches(model, world) do
    for {conv, c} <- Enum.with_index(model.convs), {user, p} <- Enum.with_index(world.users) do
      conversation = Repo.get!(Conversation, conv.id)

      assert can_read?(user, conversation) == reader?(model, c, p),
             "person #{p} reading #{inspect(conv)} with members #{inspect(model.members)}"

      assert Messaging.participant?(conversation, user) == (Map.get(conv.people, p) == :active)
    end

    for {user, p} <- Enum.with_index(world.users) do
      inbox = Messaging.inbox(user, 1).entries
      expected = for conv <- model.convs, Map.get(conv.people, p) == :active, do: conv.id
      assert Enum.sort(Enum.map(inbox, & &1.id)) == Enum.sort(expected)

      for entry <- inbox do
        conv = Enum.find(model.convs, &(&1.id == entry.id))
        assert entry.unread_count == conv.messages - Map.get(conv.read, p, 0)
      end
    end
  end

  test "any sequence keeps access, inboxes and unread counts as the model says" do
    admin = admin_fixture()

    check all(commands <- list_of(command(), min_length: 1, max_length: 16), max_runs: runs(40)) do
      users =
        for _ <- 1..@people,
            do: user_fixture(%{username: "m#{System.unique_integer([:positive])}"})

      {:ok, group} = Groups.create_group(%{name: "g#{System.unique_integer([:positive])}"}, admin)

      {:ok, group} =
        Groups.update_settings(
          group,
          %{visibility: "public", messageable: "everyone", membership: "open"},
          admin
        )

      world = %{users: users, group: group, admin: admin}
      model = %{convs: [], members: MapSet.new()}

      Enum.reduce(commands, model, fn command, model ->
        model = step(command, model, world)
        assert_matches(model, world)
        model
      end)
    end
  end

  property "recipients of any shape are refused or resolved, never crash" do
    sender = user_fixture()
    other = user_fixture()

    check all(
            recipients <-
              one_of([
                adversarial_text(6),
                map(list_of(username(), max_length: 3), &Enum.join(&1, ", "))
              ]),
            max_runs: runs(60)
          ) do
      attrs = %{
        "title" => "A fine title",
        "body" => "Hello there.",
        "recipients" => recipients <> " " <> other.username
      }

      case Messaging.start_conversation(sender, attrs) do
        {:ok, conversation} -> assert Messaging.participant?(conversation, other)
        {:error, %Ecto.Changeset{} = changeset} -> assert changeset.errors != []
      end
    end
  end
end
