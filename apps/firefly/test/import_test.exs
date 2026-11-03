defmodule Firefly.ImportTest do
  use Firefly.DataCase

  import Firefly.Fixtures

  alias Firefly.{Chat, Import}
  alias Firefly.Accounts.User
  alias Firefly.Import.Writer

  describe "runs" do
    test "keep their options without secrets, their counts and log" do
      {:ok, run} =
        Import.start_run("discourse",
          source_url: "postgres://admin:hunter2@db.example.com/discourse",
          token: "ghp_secret",
          batch_size: 100
        )

      assert run.options == %{
               "source_url" => "postgres://[redacted]@db.example.com/discourse",
               "token" => "[redacted]",
               "batch_size" => 100
             }

      run = Import.update_run(run, %{"posts" => %{"imported" => 1}}, ["posts: 1 imported"])
      run = Import.finish_run(run, "finished", %{"posts" => %{"imported" => 2}}, ["Done."])
      assert run.status == "finished"
      assert run.finished_at
      assert run.log == ["posts: 1 imported", "Done."]
      assert [%{id: id}] = Import.list_runs()
      assert id == run.id
    end
  end

  describe "the id map" do
    test "maps a source's ids to local ones" do
      :ok = Import.put_id("phpbb", "user", 7, 70)
      :ok = Import.put_id("phpbb", "user", "8", 80)
      :ok = Import.put_id("vbulletin", "user", 7, 71)

      assert Import.mapped("phpbb", "user", [7, 8, 9]) == %{"7" => 70, "8" => 80}
      assert Import.local_id("vbulletin", "user", 7) == 71
      assert Import.local_id("phpbb", "thread", 7) == nil
      assert Import.imported_counts("phpbb") == %{"user" => 2}
    end
  end

  describe "permalinks" do
    setup do
      user = user_fixture()
      thread = thread_fixture(category_fixture(), user)
      {:ok, thread: thread, user: user}
    end

    test "find old URLs, with their query, single parameters or a shorter path", %{
      thread: thread,
      user: user
    } do
      {:ok, _} = Import.put_permalink("phpbb", "/viewtopic.php?t=12", {:thread_id, thread.id})

      {:ok, _} =
        Import.put_permalink(
          "discourse",
          "https://old.example.com/t/hi/12/",
          {:thread_id, thread.id}
        )

      {:ok, _} = Import.put_permalink("discourse", "u/Ada%20L", {:user_id, user.id})

      {:ok, _} =
        Import.put_permalink("discourse", "about", {:external_url, "https://example.org"})

      assert Import.find_permalink("/viewtopic.php", "t=12").thread.id == thread.id
      assert Import.find_permalink("/viewtopic.php", "f=2&t=12&sid=abc").thread.id == thread.id
      assert Import.find_permalink("/t/hi/12").thread.id == thread.id
      assert Import.find_permalink("/t/hi/12/5").thread.id == thread.id
      assert Import.find_permalink("/u/Ada L").user.id == user.id
      assert Import.find_permalink("/about/").external_url == "https://example.org"
      assert Import.find_permalink("/viewtopic.php", "t=13") == nil
      assert Import.find_permalink("/") == nil
    end

    test "keep the first target of a URL and need one", %{thread: thread, user: user} do
      {:ok, _} = Import.put_permalink("discourse", "t/12", {:thread_id, thread.id})
      {:ok, %{id: nil}} = Import.put_permalink("discourse", "t/12", {:user_id, user.id})
      assert {:error, :no_target} = Import.put_permalink("discourse", "t/13", {:thread_id, nil})
      assert Import.find_permalink("/t/12").thread_id == thread.id
    end
  end

  describe "the writer" do
    test "makes usernames valid and unique, in any case" do
      user_fixture(%{username: "Ada_Lovelace"})
      assert Writer.unique_username("ada.lovelace") == "ada_lovelace2"
      assert Writer.unique_username("Zoë Smith") == "Zoe_Smith"
      assert Writer.unique_username("x") == "user_x"
      assert Writer.unique_username("deleted-user-5") == "user_deleted-user-5"
      assert String.length(Writer.unique_username(String.duplicate("a", 40))) == 32
    end

    test "imports users without passwords, with their dates" do
      {:ok, user} =
        Writer.user(%{
          username: "ada",
          email: "ada@example.com",
          confirmed: true,
          created_at: ~U[2019-05-06 07:08:09Z],
          website: "javascript:alert(1)",
          identities: [%{provider: "github", uid: 1}]
        })

      assert %User{password_hash: nil, website: nil} = user
      assert user.inserted_at == ~N[2019-05-06 07:08:09.000000]
      assert user.confirmed_at == ~U[2019-05-06 07:08:09Z]

      # The same person again: by their login, or by their email.
      assert {:ok, %{id: id}} =
               Writer.user(%{username: "other", identities: [%{provider: "github", uid: "1"}]})

      assert id == user.id
      assert {:ok, %{id: ^id}} = Writer.user(%{username: "ada2", email: "ADA@example.com"})
    end

    test "makes tag names valid and tags once, in a group" do
      assert Writer.tag_name("Phoenix Framework!") == "phoenix-framework"
      {:ok, tag} = Writer.tag("Phoenix Framework", "Web")
      {:ok, again} = Writer.tag("phoenix-framework")
      assert tag.id == again.id
      assert Firefly.Repo.preload(tag, :group).group.name == "Web"
      assert {:ok, nil} = Writer.tag("!!!")
    end

    test "imports chat channels with unique slugs, messages and threads" do
      user = user_fixture()
      {:ok, general} = Writer.chat_channel(%{name: "General", member_ids: [user.id]})
      {:ok, again} = Writer.chat_channel(%{name: "general"})
      assert {general.slug, again.slug} == {"general", "general-2"}

      {:ok, root} =
        Writer.chat_message(%{
          channel_id: general.id,
          user_id: user.id,
          body: "Hi",
          created_at: ~N[2020-01-01 10:00:00]
        })

      {:ok, reply} =
        Writer.chat_message(%{
          channel_id: general.id,
          user_id: user.id,
          body: "Hello",
          thread_root_id: root.id,
          created_at: ~N[2020-01-01 10:05:00]
        })

      thread = Firefly.Repo.get_by!(Chat.Thread, original_message_id: root.id)
      assert reply.thread_id == thread.id
      assert Firefly.Repo.get!(Chat.Message, root.id).thread_id == thread.id
      assert thread.last_reply_at == ~N[2020-01-01 10:05:00.000000]

      assert Firefly.Repo.get!(Chat.Channel, general.id).last_message_at ==
               ~N[2020-01-01 10:05:00.000000]

      {:ok, _} = Writer.reaction(reply.id, user.id, "tada")
      {:ok, _} = Writer.reaction(reply.id, user.id, "tada")
      assert Firefly.Repo.aggregate(Chat.Reaction, :count) == 1
    end
  end

  test "after an import, updates what's derived from the content" do
    assert ["Refreshed the directory's stats.", "Granted badges.", "Reviewed trust levels."] =
             Import.after_import()
  end
end
