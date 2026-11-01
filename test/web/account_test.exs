defmodule FirestormWeb.Web.AccountTest do
  use FirestormWeb.Web.ConnCase
  use Bamboo.Test, shared: true

  import Ecto.Query, only: [from: 2]

  alias FirestormWeb.{
    AccountDeletion,
    AccountExport,
    Forums,
    Messages,
    Notifications,
    PasswordReset,
    RateLimit,
    Repo
  }

  alias FirestormWeb.Forums.{Post, PostLike, Subscriptions, User}

  setup do
    {:ok, _} = Notifications.start_link()

    {:ok, ada} =
      Forums.register_user(%{username: "ada", email: "ada@example.com", password: "ada-password"})

    {:ok, ada} = Forums.confirm_user(ada)

    bob =
      user_fixture(%{username: "bob", email: "bob-secret@example.com", name: "Robert Secret"})

    category = category_fixture("Elixir")
    {:ok, tag_category} = Forums.create_category(%{title: "Watched category"})

    thread =
      thread_fixture(category, ada, %{title: "Ada's thread", body: "My first post", tags: "beam"})

    [first] = Repo.preload(thread, :posts).posts
    {:ok, _} = Forums.update_post(first, ada, %{body: "My first post, edited"})

    {:ok, bob_reply} = Forums.create_post(thread, bob, %{body: "bob's public reply @ada"})
    :ok = Forums.like_post(first, bob)
    :ok = Forums.like_post(bob_reply, ada)
    {:ok, _} = Subscriptions.set_category_level(ada, tag_category, "tracking")
    {:ok, _} = Subscriptions.set_tag_level(ada, Forums.get_tag!("beam"), "watching")
    Forums.mark_thread_read(ada, thread)

    {:ok, conversation} =
      Messages.start_conversation(bob, %{
        "recipients" => "ada",
        "title" => "A private chat",
        "body" => "bob's private words"
      })

    {:ok, _} = Messages.reply(conversation, ada, %{body: "Ada's private answer"})
    :sys.get_state(Notifications)

    %{
      ada: Forums.get_user!(ada.id),
      bob: bob,
      thread: thread,
      first: first,
      conversation: conversation
    }
  end

  describe "export" do
    test "has the user's own data", %{
      ada: ada,
      thread: thread,
      first: first,
      conversation: conversation
    } do
      data = AccountExport.build(ada)

      assert data.profile.email == "ada@example.com"
      assert data.preferences.theme == "system"

      assert [%{id: post_id, body: "My first post, edited", revisions: [revision]}] = data.posts
      assert post_id == first.id
      assert revision.previous_body == "My first post"

      assert [%{title: "Ada's thread", category: "Elixir"}] = data.threads_started
      assert [%{thread_id: liked_thread}] = data.likes
      assert liked_thread == thread.id
      assert Enum.any?(data.notifications, &(&1.kind == "mentioned"))
      assert Enum.all?(data.notifications, &(not Map.has_key?(&1, :body)))

      assert [chat] = data.conversations
      assert chat.id == conversation.id
      assert chat.started_by == "bob"
      assert Enum.sort(chat.participants) == ["ada", "bob"]
      assert [%{body: "Ada's private answer"}] = chat.your_messages

      assert [%{level: "watching"}] = data.notification_levels.threads

      assert [%{category: "Watched category", level: "tracking"}] =
               data.notification_levels.categories

      assert [%{tag: "beam", level: "watching"}] = data.notification_levels.tags
      assert [%{thread_id: _}] = data.read_positions
    end

    test "says nothing about other users beyond their usernames", %{ada: ada, bob: bob} do
      json = AccountExport.to_json(ada)

      assert json =~ ~s{"bob"}
      refute json =~ "bob-secret@example.com"
      refute json =~ "Robert Secret"
      refute json =~ bob.api_token
      refute json =~ "bob's private words"
      refute json =~ "bob's public reply"
      refute json =~ ada.api_token
      refute json =~ "password"
    end

    test "downloads as a JSON file, rate limited", %{conn: conn, ada: ada} do
      conn = log_in_as(conn, ada)
      response = get(conn, ~p"/settings/export")

      assert response.status == 200
      assert [disposition] = get_resp_header(response, "content-disposition")
      assert disposition =~ "attachment"
      assert disposition =~ "firefly-ada-"
      assert %{"profile" => %{"username" => "ada"}} = Jason.decode!(response.resp_body)

      config = Application.get_env(:firestorm_web, RateLimit)
      Application.put_env(:firestorm_web, RateLimit, limits: [export: {0, 60_000}])
      on_exit(fn -> Application.put_env(:firestorm_web, RateLimit, config) end)

      assert conn |> get(~p"/settings/export") |> redirected_to() == ~p"/settings/account"
      assert build_conn() |> get(~p"/settings/export") |> redirected_to() == ~p"/categories"
    end
  end

  describe "deletion" do
    test "needs the password; then anonymizes the account and keeps its content", ctx do
      %{conn: conn, ada: ada, bob: bob, thread: thread, first: first, conversation: conversation} =
        ctx

      reset_token = PasswordReset.token(ada)

      conn
      |> log_in_as(ada)
      |> visit(~p"/settings/account")
      |> fill_in("Your password", with: "wrong-password")
      |> click_button("Delete my account")
      |> assert_has("#flash-error", text: "That doesn't match")

      refute User.deleted?(Forums.get_user!(ada.id))

      conn
      |> log_in_as(ada)
      |> visit(~p"/settings/account")
      |> fill_in("Your password", with: "ada-password")
      |> click_button("Delete my account")
      |> assert_path(~p"/")
      |> assert_has("#flash-info", text: "Your account was deleted.")
      |> assert_has("nav a", text: "Log in")

      gone = Forums.get_user!(ada.id)
      assert gone.username == "deleted-user-#{ada.id}"
      assert %{email: nil, password_hash: nil, github_uid: nil, bio: nil} = gone
      assert gone.api_token != ada.api_token

      # Content stays, credited to the placeholder.
      assert Repo.get!(Post, first.id).user_id == ada.id

      assert [%{body: "Ada's private answer"}] =
               conversation |> Messages.messages() |> Enum.filter(&(&1.user_id == ada.id))

      conn
      |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}")
      |> assert_has("#posts", text: "@deleted-user-#{ada.id}")
      |> refute_has("#posts", text: "@ada ")

      # Personal data goes.
      assert Forums.notifications_for(gone) == []
      assert Repo.all(from l in PostLike, where: l.user_id == ^ada.id) == []
      assert Subscriptions.thread_level(gone, thread) == nil
      assert Forums.thread_read(gone, thread) == nil
      refute Messages.participant?(conversation, gone)
      assert Messages.participants(conversation) |> Enum.map(& &1.username) == ["bob"]

      # Every way back in is closed.
      conn |> log_in_as(ada) |> visit(~p"/") |> assert_has("nav a", text: "Log in")
      assert {:error, _} = Forums.authenticate_by_password("ada", "ada-password")
      assert PasswordReset.verify(reset_token) == {:error, :invalid}

      api =
        build_conn()
        |> put_req_header("authorization", "Bearer #{ada.api_token}")
        |> post(~p"/api/v1/posts", post: %{body: "hi"}, thread_id: thread.id)

      assert api.status == 401

      # The placeholder can't be mentioned or messaged.
      assert Forums.users_by_username(["deleted-user-#{ada.id}"]) == %{}

      assert {:error, _} =
               Messages.start_conversation(bob, %{
                 "recipients" => "deleted-user-#{ada.id}",
                 "title" => "t",
                 "body" => "b"
               })
    end

    test "GitHub accounts confirm with their username", %{conn: conn} do
      {:ok, octo} =
        Forums.login_or_register_from_github(%{uid: 42, nickname: "Octo", name: "Octo Cat"})

      conn
      |> log_in_as(octo)
      |> visit(~p"/settings/account")
      |> fill_in("Type your username (Octo) to confirm", with: "nope")
      |> click_button("Delete my account")
      |> assert_has("#flash-error", text: "That doesn't match")

      conn
      |> log_in_as(octo)
      |> visit(~p"/settings/account")
      |> fill_in("Type your username (Octo) to confirm", with: "octo")
      |> click_button("Delete my account")
      |> assert_has("#flash-info", text: "Your account was deleted.")

      assert %{github_uid: nil, deleted_at: %DateTime{}} = Forums.get_user!(octo.id)

      # The GitHub account can sign up afresh.
      assert {:ok, again} = Forums.login_or_register_from_github(%{uid: 42, nickname: "Octo"})
      assert again.id != octo.id
    end

    test "the last admin can't delete themselves" do
      admin = admin_fixture(%{username: "boss"})

      assert AccountDeletion.delete_account(admin, "boss") == {:error, :last_admin}

      admin_fixture()
      assert {:ok, _} = AccountDeletion.delete_account(admin, "boss")
    end

    test "logging in ties LiveViews to the account; deletion disconnects them", %{ada: ada} do
      conn =
        post(build_conn(), "/auth/identity/callback", %{
          "user" => %{"username" => "ada", "password" => "ada-password"}
        })

      assert get_session(conn, :live_socket_id) == "users_sockets:#{ada.id}"

      FirestormWeb.Web.Endpoint.subscribe("users_sockets:#{ada.id}")
      {:ok, _} = AccountDeletion.delete_account(ada, "ada-password")
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end
end
