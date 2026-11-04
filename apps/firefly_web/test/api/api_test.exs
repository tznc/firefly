defmodule FireflyWeb.Api.ApiTest do
  use FireflyWeb.ConnCase, async: false

  alias Firefly.{Accounts, Chat, Discussion, Groups, Messaging, Notifications, SiteSettings}
  alias Firefly.Accounts.ApiKeys
  alias Firefly.Discussion.{Bookmarks, Polls}
  alias Firefly.Moderation.Flags

  setup do
    admin = admin_fixture()
    member = user_fixture()
    category = category_fixture("Elixir")
    thread = thread_fixture(category, member, %{title: "OTP is cool", body: "Don't you think?"})

    %{admin: admin, member: member, category: category, thread: thread}
  end

  describe "authentication" do
    test "visitors read public content and are refused writes", %{conn: conn, thread: thread} do
      assert [listed] =
               conn |> get(~p"/api/v1/threads") |> json_response(200) |> assert_list("Thread")

      assert listed["id"] == thread.id

      conn = post(conn, ~p"/api/v1/threads", %{})
      assert ["application/problem+json" <> _] = get_resp_header(conn, "content-type")
      assert %{"status" => 401} = conn |> json_response(401) |> assert_schema("Problem")
      assert ["Bearer realm=\"firefly\"" <> _] = get_resp_header(conn, "www-authenticate")
    end

    test "an invalid or revoked key is 401", %{conn: conn, member: member} do
      assert conn
             |> put_req_header("authorization", "Bearer ffk_nope")
             |> get(~p"/api/v1/me")
             |> json_response(401)

      {:ok, key, token} = ApiKeys.create(member, %{name: "k", scopes: ["read"]})
      {:ok, _} = ApiKeys.revoke(key, member)

      assert conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(~p"/api/v1/me")
             |> json_response(401)
    end

    test "a key only used from allowed addresses is 403 elsewhere", %{conn: conn, member: member} do
      {:ok, _key, token} =
        ApiKeys.create(member, %{name: "k", scopes: ["read"], allowed_ips: ["10.0.0.0/8"]})

      assert conn
             |> put_req_header("authorization", "Bearer #{token}")
             |> get(~p"/api/v1/me")
             |> json_response(403)
    end

    test "over the key's rate limit is 429 with Retry-After", %{conn: conn, member: member} do
      {:ok, _key, token} = ApiKeys.create(member, %{name: "k", scopes: ["read"], rate_limit: 1})
      authed = put_req_header(conn, "authorization", "Bearer #{token}")

      assert authed |> get(~p"/api/v1/me") |> json_response(200)
      over = get(authed, ~p"/api/v1/me")
      assert json_response(over, 429)
      assert get_resp_header(over, "retry-after") == ["60"]
    end

    test "a global key acts as the user the request names", %{
      conn: conn,
      admin: admin,
      member: member
    } do
      {:ok, _key, token} = ApiKeys.create_global(admin, %{name: "CI", scopes: ["read"]})

      body =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("api-username", member.username)
        |> get(~p"/api/v1/me")
        |> json_response(200)

      assert body["data"]["username"] == member.username
      assert body["data"]["api_key"]["global"]
    end

    test "every write endpoint is refused without its scope", %{
      conn: conn,
      member: member,
      thread: thread
    } do
      read_only = authed(conn, member, ["read"])

      assert %{"detail" => detail} =
               read_only
               |> post(~p"/api/v1/threads/#{thread.id}/posts", %{body: "hi"})
               |> json_response(403)

      assert detail =~ "topics:write"

      assert read_only |> get(~p"/api/v1/admin/site-settings") |> json_response(403)
      assert read_only |> get(~p"/api/v1/review") |> json_response(403)
    end

    test "the write scope covers the per-resource write scopes", %{
      conn: conn,
      member: member,
      thread: thread
    } do
      assert conn
             |> authed(member, ["write"])
             |> post(~p"/api/v1/threads/#{thread.id}/posts", %{body: "with write"})
             |> json_response(201)
    end

    test "the API password login hands out a full-scope key", %{conn: conn} do
      {:ok, user} =
        Accounts.register_user(%{
          username: "ada",
          email: "ada@example.com",
          password: "ada-password"
        })

      {:ok, _user} = Accounts.confirm_user(user)

      token =
        conn
        |> post(~p"/api/v1/auth/identity", user: %{username: "ada", password: "ada-password"})
        |> json_response(200)
        |> get_in(["data", "api_token"])

      assert {:ok, key, _user} = ApiKeys.authenticate(token, {127, 0, 0, 1})
      assert Enum.sort(key.scopes) == Enum.sort(ApiKeys.full_scopes())
    end
  end

  describe "pagination" do
    test "limits, cursors and the last page", %{conn: conn, member: member, category: category} do
      for n <- 1..4, do: thread_fixture(category, member, %{title: "Thread #{n}", body: "Body"})

      first = conn |> get(~p"/api/v1/threads?limit=2") |> json_response(200)
      assert length(first["data"]) == 2
      assert first["meta"]["limit"] == 2
      assert cursor = first["meta"]["next_cursor"]

      second = conn |> get(~p"/api/v1/threads?limit=2&cursor=#{cursor}") |> json_response(200)
      assert length(second["data"]) == 2

      refute Enum.any?(
               second["data"],
               &(&1["id"] in Enum.map(first["data"], fn t -> t["id"] end))
             )

      last = conn |> get(~p"/api/v1/threads?limit=10") |> json_response(200)
      assert last["meta"]["next_cursor"] == nil

      assert %{"status" => 400} =
               conn |> get(~p"/api/v1/threads?cursor=nonsense") |> json_response(400)
    end
  end

  describe "categories" do
    test "lists and reads what the user may see", %{
      conn: conn,
      member: member,
      category: category
    } do
      {:ok, team} = Groups.create_role("team")
      {:ok, secret} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})

      titles =
        conn
        |> authed(member)
        |> get(~p"/api/v1/categories")
        |> json_response(200)
        |> assert_list("Category")
        |> Enum.map(& &1["title"])

      assert titles == ["Elixir"]

      assert conn
             |> authed(member)
             |> get(~p"/api/v1/categories/#{secret.id}")
             |> json_response(404)

      assert conn
             |> authed(member)
             |> get(~p"/api/v1/categories/#{category.id}")
             |> json_response(200)
    end

    test "admins create, edit and delete them", %{conn: conn, admin: admin, member: member} do
      authed_admin = authed(conn, admin)

      created =
        authed_admin
        |> post(~p"/api/v1/categories", %{title: "Erlang", description: "BEAM"})
        |> json_response(201)
        |> Map.fetch!("data")
        |> assert_schema("Category")

      assert created["title"] == "Erlang"

      assert authed_admin
             |> patch(~p"/api/v1/categories/#{created["id"]}", %{title: "BEAM"})
             |> json_response(200)
             |> get_in(["data", "title"]) == "BEAM"

      assert conn
             |> authed(member)
             |> delete(~p"/api/v1/categories/#{created["id"]}")
             |> json_response(403)

      assert authed_admin |> delete(~p"/api/v1/categories/#{created["id"]}") |> response(204)
    end

    test "a notification level", %{conn: conn, member: member, category: category} do
      assert conn
             |> authed(member)
             |> put(~p"/api/v1/categories/#{category.id}/notification-level", %{level: "watching"})
             |> json_response(200)

      assert %{"status" => 422} =
               conn
               |> authed(member)
               |> put(~p"/api/v1/categories/#{category.id}/notification-level", %{level: "loud"})
               |> json_response(422)
    end
  end

  describe "threads" do
    test "the views", %{conn: conn, member: member, category: category, thread: thread} do
      reader = user_fixture()

      assert [%{"id" => id}] =
               conn
               |> authed(reader)
               |> get(~p"/api/v1/threads?view=new")
               |> json_response(200)
               |> Map.fetch!("data")

      assert id == thread.id

      assert conn |> get(~p"/api/v1/threads?view=new") |> json_response(401)
      assert conn |> get(~p"/api/v1/threads?view=top&period=week") |> json_response(200)

      assert %{"status" => 422} =
               conn |> get(~p"/api/v1/threads?view=sideways") |> json_response(422)

      {:ok, _} = Discussion.create_thread(category, member, %{title: "Second", body: "Hello"})

      assert length(conn |> get(~p"/api/v1/threads") |> json_response(200) |> Map.fetch!("data")) ==
               2
    end

    test "creating, editing and deleting", %{conn: conn, member: member, category: category} do
      authed_member = authed(conn, member)

      created =
        authed_member
        |> post(~p"/api/v1/threads", %{
          category_id: category.id,
          title: "From the API",
          body: "Hello there",
          tags: ["otp", "beam"]
        })
        |> json_response(201)
        |> Map.fetch!("data")
        |> assert_schema("Thread")

      assert created["title"] == "From the API"
      assert Enum.sort(created["tags"]) == ["beam", "otp"]

      assert authed_member
             |> patch(~p"/api/v1/threads/#{created["id"]}", %{title: "Renamed"})
             |> json_response(200)
             |> get_in(["data", "title"]) == "Renamed"

      assert conn
             |> authed(user_fixture())
             |> patch(~p"/api/v1/threads/#{created["id"]}", %{title: "Nope"})
             |> json_response(403)

      assert authed_member |> delete(~p"/api/v1/threads/#{created["id"]}") |> response(204)
    end

    test "the topic tools follow the UI's permissions", %{
      conn: conn,
      admin: admin,
      member: member,
      thread: thread
    } do
      assert conn
             |> authed(member)
             |> post(~p"/api/v1/threads/#{thread.id}/close")
             |> json_response(403)

      assert conn
             |> authed(admin)
             |> post(~p"/api/v1/threads/#{thread.id}/close")
             |> json_response(200)
             |> get_in(["data", "closed"])

      assert conn
             |> authed(admin)
             |> post(~p"/api/v1/threads/#{thread.id}/pin", %{value: true})
             |> json_response(200)
             |> get_in(["data", "pinned"])

      {:ok, other} = Discussion.create_category(%{title: "Erlang"})

      assert conn
             |> authed(admin)
             |> post(~p"/api/v1/threads/#{thread.id}/move", %{category_id: other.id})
             |> json_response(200)
             |> get_in(["data", "category_id"]) == other.id
    end

    test "posts, replies and read state", %{conn: conn, member: member, thread: thread} do
      authed_member = authed(conn, member)

      reply =
        authed_member
        |> post(~p"/api/v1/threads/#{thread.id}/posts", %{body: "A reply"})
        |> json_response(201)
        |> Map.fetch!("data")
        |> assert_schema("Post")

      assert reply["body_html"] =~ "A reply"

      posts =
        conn
        |> get(~p"/api/v1/threads/#{thread.id}/posts")
        |> json_response(200)
        |> assert_list("Post")

      assert Enum.map(posts, & &1["body"]) == ["Don't you think?", "A reply"]
      assert authed_member |> post(~p"/api/v1/threads/#{thread.id}/read") |> response(204)
      assert Discussion.thread_read(member, thread) != nil
    end

    test "a closed thread refuses replies", %{
      conn: conn,
      admin: admin,
      member: member,
      thread: thread
    } do
      {:ok, thread} = Discussion.close_thread(thread, true, admin)

      assert %{"detail" => detail} =
               conn
               |> authed(member)
               |> post(~p"/api/v1/threads/#{thread.id}/posts", %{body: "hi"})
               |> json_response(403)

      assert detail =~ "closed"
    end

    test "accepted answers", %{conn: conn, member: member, category: category} do
      {:ok, category} = Discussion.update_category(category, %{allow_accepted_answers: true}, nil)
      thread = thread_fixture(category, member, %{title: "Question", body: "How?"})
      {:ok, answer} = Discussion.create_post(thread, user_fixture(), %{body: "Like this"})

      assert conn
             |> authed(member)
             |> put(~p"/api/v1/threads/#{thread.id}/solution", %{post_id: answer.id})
             |> json_response(200)
             |> get_in(["data", "accepted_post_id"]) == answer.id

      assert conn
             |> authed(member)
             |> delete(~p"/api/v1/threads/#{thread.id}/solution")
             |> json_response(200)
             |> get_in(["data", "accepted_post_id"]) == nil
    end
  end

  describe "posts" do
    setup %{thread: thread, member: member} do
      {:ok, reply} = Discussion.create_post(thread, member, %{body: "The reply"})
      %{reply: reply}
    end

    test "editing and deleting, with the UI's rules", %{conn: conn, member: member, reply: reply} do
      assert conn
             |> authed(member)
             |> patch(~p"/api/v1/posts/#{reply.id}", %{body: "Edited"})
             |> json_response(200)
             |> get_in(["data", "body"]) == "Edited"

      assert conn
             |> authed(user_fixture())
             |> patch(~p"/api/v1/posts/#{reply.id}", %{body: "Not mine"})
             |> json_response(403)

      assert conn |> authed(member) |> delete(~p"/api/v1/posts/#{reply.id}") |> response(204)

      assert conn
             |> get(~p"/api/v1/posts/#{reply.id}")
             |> json_response(200)
             |> get_in(["data", "body"]) == ""
    end

    test "a thread's first post can't be deleted on its own", %{
      conn: conn,
      member: member,
      thread: thread
    } do
      [first | _] = Firefly.Repo.preload(thread, :posts).posts

      assert %{"status" => 422} =
               conn
               |> authed(member)
               |> delete(~p"/api/v1/posts/#{first.id}")
               |> json_response(422)
    end

    test "likes and bookmarks", %{conn: conn, reply: reply} do
      other = user_fixture()
      authed_other = authed(conn, other)

      liked = authed_other |> put(~p"/api/v1/posts/#{reply.id}/like") |> json_response(200)
      assert liked["data"]["liked"]
      assert liked["data"]["like_count"] == 1

      assert authed_other
             |> delete(~p"/api/v1/posts/#{reply.id}/like")
             |> json_response(200)
             |> get_in(["data", "like_count"]) == 0

      assert authed_other
             |> put(~p"/api/v1/posts/#{reply.id}/bookmark", %{note: "Read later"})
             |> json_response(200)
             |> get_in(["data", "note"]) == "Read later"

      assert [%{"note" => "Read later"}] =
               authed_other
               |> get(~p"/api/v1/bookmarks")
               |> json_response(200)
               |> assert_list("BookmarkListed")

      assert authed_other |> delete(~p"/api/v1/posts/#{reply.id}/bookmark") |> response(204)
      assert Bookmarks.list(other) == []
    end

    test "nobody likes their own post", %{conn: conn, member: member, reply: reply} do
      assert conn
             |> authed(member)
             |> put(~p"/api/v1/posts/#{reply.id}/like")
             |> json_response(403)
    end

    test "flags reach the review queue", %{conn: conn, admin: admin, reply: reply} do
      flagger = user_fixture()

      assert conn
             |> authed(flagger)
             |> post(~p"/api/v1/posts/#{reply.id}/flags", %{reason: "spam", note: "Looks off"})
             |> json_response(201)

      assert [%{"kind" => "flagged"} = item] =
               conn
               |> authed(admin)
               |> get(~p"/api/v1/review")
               |> json_response(200)
               |> assert_list("ReviewItem")

      assert item["post"]["id"] == reply.id

      assert conn
             |> authed(admin)
             |> post(~p"/api/v1/review/posts/#{reply.id}/agree", %{action: "hide"})
             |> response(204)

      assert Firefly.Repo.get!(Firefly.Discussion.Post, reply.id).hidden_at != nil
      assert Flags.pending_counts([reply]) == %{}
    end

    test "polls: reading, voting and closing", %{conn: conn, member: member, category: category} do
      thread =
        thread_fixture(category, member, %{
          title: "Poll",
          body: "Pick one",
          poll: Polls.attrs(%{"enabled" => "true", "options_text" => "Yes\nNo"}, 0)
        })

      [post | _] = Firefly.Repo.preload(thread, :posts).posts
      voter = user_fixture()

      poll =
        conn |> get(~p"/api/v1/posts/#{post.id}/poll") |> json_response(200) |> Map.fetch!("data")

      assert_schema(poll, "Poll")
      [%{"id" => yes} | _] = poll["options"]

      voted =
        conn
        |> authed(voter)
        |> post(~p"/api/v1/posts/#{post.id}/poll/vote", %{option: yes})
        |> json_response(200)
        |> Map.fetch!("data")

      assert voted["mine"] == [yes]
      assert voted["voters"] == 1

      assert conn
             |> authed(member)
             |> post(~p"/api/v1/posts/#{post.id}/poll/close")
             |> json_response(200)
             |> get_in(["data", "closed"])
    end

    test "wiki posts", %{conn: conn, admin: admin, member: member, reply: reply} do
      assert conn
             |> authed(member)
             |> put(~p"/api/v1/posts/#{reply.id}/wiki")
             |> json_response(403)

      assert conn
             |> authed(admin)
             |> put(~p"/api/v1/posts/#{reply.id}/wiki", %{wiki: true})
             |> json_response(200)
             |> get_in(["data", "wiki"])
    end

    test "previews render markdown", %{conn: conn} do
      assert conn
             |> post(~p"/api/v1/preview", %{body: "**neat**"})
             |> json_response(201)
             |> get_in(["data", "html"]) =~ "<strong>neat</strong>"
    end
  end

  describe "tags" do
    test "lists tags and their threads, and takes a level", %{
      conn: conn,
      member: member,
      category: category
    } do
      {:ok, _thread} =
        Discussion.create_thread(category, member, %{title: "Tagged", body: "Hello", tags: "otp"})

      assert [%{"name" => "otp", "threads_count" => 1}] =
               conn |> get(~p"/api/v1/tags") |> json_response(200) |> assert_list("Tag")

      assert [%{"title" => "Tagged"}] =
               conn
               |> get(~p"/api/v1/tags/otp/threads")
               |> json_response(200)
               |> assert_list("Thread")

      assert conn
             |> authed(member)
             |> put(~p"/api/v1/tags/otp/notification-level", %{level: "muted"})
             |> json_response(200)

      assert conn |> get(~p"/api/v1/tags/nope/threads") |> json_response(404)
    end
  end

  describe "users" do
    test "the directory, profiles and activity", %{conn: conn, member: member} do
      assert conn |> get(~p"/api/v1/users") |> json_response(200) |> assert_list("DirectoryEntry")

      assert conn
             |> get(~p"/api/v1/users/#{member.username}")
             |> json_response(200)
             |> Map.fetch!("data")
             |> assert_schema("Profile")

      assert [%{"body" => "Don't you think?"}] =
               conn
               |> get(~p"/api/v1/users/#{member.username}/posts")
               |> json_response(200)
               |> Map.fetch!("data")

      assert conn |> get(~p"/api/v1/users/nobody") |> json_response(404)
    end

    test "a hidden profile is 404", %{conn: conn, member: member} do
      {:ok, member} = Accounts.update_preferences(member, %{hide_profile: true})
      assert conn |> get(~p"/api/v1/users/#{member.username}") |> json_response(404)
    end

    test "me, and updating the profile and preferences", %{conn: conn, member: member} do
      authed_member = authed(conn, member)

      me = authed_member |> get(~p"/api/v1/me") |> json_response(200) |> Map.fetch!("data")
      assert_schema(me, "Me")
      assert me["username"] == member.username

      assert authed_member
             |> patch(~p"/api/v1/me", %{name: "Renamed", email: "nope@example.com"})
             |> json_response(200)
             |> get_in(["data", "name"]) == "Renamed"

      # The email isn't a profile field: it needs confirmation.
      assert Accounts.get_user!(member.id).email == member.email

      assert authed_member
             |> patch(~p"/api/v1/me/preferences", %{theme: "dark"})
             |> json_response(200)
             |> get_in(["data", "preferences", "theme"]) == "dark"
    end

    test "admins silence and suspend, and lift it", %{conn: conn, admin: admin, member: member} do
      authed_admin = authed(conn, admin)

      silenced =
        authed_admin
        |> post(~p"/api/v1/users/#{member.username}/penalties/silence", %{
          duration: "1d",
          reason: "Spam"
        })
        |> json_response(200)
        |> Map.fetch!("data")

      assert_schema(silenced, "Penalized")
      assert silenced["silenced_until"]

      assert conn
             |> authed(member)
             |> post(~p"/api/v1/users/#{admin.username}/penalties/silence", %{reason: "no"})
             |> json_response(403)

      assert authed_admin
             |> delete(~p"/api/v1/users/#{member.username}/penalties/silence")
             |> json_response(200)
             |> get_in(["data", "silenced_until"]) == nil
    end
  end

  describe "notifications" do
    test "lists and marks read", %{conn: conn, member: member, thread: thread} do
      {:ok, notification} =
        Notifications.notify(member, %{
          kind: "mentioned",
          thread_id: thread.id,
          subject: "Hi",
          body: "You were mentioned",
          url: "/categories/#{thread.category_id}/threads/#{thread.id}"
        })

      authed_member = authed(conn, member)
      listing = get(authed_member, ~p"/api/v1/notifications")
      assert get_resp_header(listing, "x-unread-count") == ["1"]
      assert [listed] = listing |> json_response(200) |> assert_list("Notification")
      refute listed["read"]

      assert authed_member
             |> post(~p"/api/v1/notifications/#{notification.id}/read")
             |> json_response(200)
             |> get_in(["data", "read"])

      assert authed_member |> post(~p"/api/v1/notifications/read") |> response(204)
      assert Notifications.unread_notification_count(member) == 0
      assert conn |> get(~p"/api/v1/notifications") |> json_response(401)
    end
  end

  describe "private messages" do
    test "start, read and reply; outsiders get 404", %{conn: conn, member: member} do
      other = user_fixture()

      id =
        conn
        |> authed(member)
        |> post(~p"/api/v1/messages", %{
          title: "Hello",
          body: "A quiet word",
          recipients: [other.username]
        })
        |> json_response(201)
        |> get_in(["data", "id"])

      conversation =
        conn
        |> authed(other)
        |> get(~p"/api/v1/messages/#{id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert_schema(conversation, "ConversationWithMessages")
      assert [%{"body" => "A quiet word"}] = conversation["messages"]

      assert conn
             |> authed(other)
             |> post(~p"/api/v1/messages/#{id}/replies", %{body: "Hello back"})
             |> json_response(201)
             |> get_in(["data", "body"]) == "Hello back"

      assert conn
             |> authed(user_fixture())
             |> get(~p"/api/v1/messages/#{id}")
             |> json_response(404)

      assert [_conversation] =
               conn
               |> authed(member)
               |> get(~p"/api/v1/messages")
               |> json_response(200)
               |> Map.fetch!("data")

      assert Messaging.unread_conversation_count(other) == 0
    end
  end

  describe "chat" do
    setup %{admin: admin} do
      {:ok, _} = SiteSettings.update(%{"chat_enabled" => "true"}, admin)
      on_exit(fn -> SiteSettings.clear_cache() end)
      {:ok, channel} = Chat.create_channel(%{name: "general"}, admin)
      %{channel: channel}
    end

    test "channels, messages and following", %{conn: conn, member: member, channel: channel} do
      authed_member = authed(conn, member)

      assert [listed] =
               authed_member
               |> get(~p"/api/v1/chat/channels/browse")
               |> json_response(200)
               |> Map.fetch!("data")

      assert_schema(listed, "ChatChannel")
      refute listed["following"]

      assert authed_member |> put(~p"/api/v1/chat/channels/#{channel.id}/follow") |> response(204)

      assert [%{"id" => id}] =
               authed_member
               |> get(~p"/api/v1/chat/channels")
               |> json_response(200)
               |> Map.fetch!("data")

      assert id == channel.id

      message =
        authed_member
        |> post(~p"/api/v1/chat/channels/#{channel.id}/messages", %{body: "Hello chat"})
        |> json_response(201)
        |> Map.fetch!("data")
        |> assert_schema("ChatMessage")

      assert [%{"body" => "Hello chat"}] =
               authed_member
               |> get(~p"/api/v1/chat/channels/#{channel.id}/messages")
               |> json_response(200)
               |> assert_list("ChatMessage")

      assert authed_member
             |> patch(~p"/api/v1/chat/messages/#{message["id"]}", %{body: "Edited"})
             |> json_response(200)
             |> get_in(["data", "body"]) == "Edited"

      assert authed_member |> delete(~p"/api/v1/chat/messages/#{message["id"]}") |> response(204)

      assert authed_member
             |> delete(~p"/api/v1/chat/channels/#{channel.id}/follow")
             |> response(204)
    end

    test "pages backwards through a channel", %{conn: conn, member: member, channel: channel} do
      for n <- 1..3, do: {:ok, _} = Chat.send_message(channel, member, %{body: "Message #{n}"})

      authed_member = authed(conn, member)

      first =
        authed_member
        |> get(~p"/api/v1/chat/channels/#{channel.id}/messages?limit=2")
        |> json_response(200)

      assert Enum.map(first["data"], & &1["body"]) == ["Message 2", "Message 3"]

      older =
        authed_member
        |> get(
          ~p"/api/v1/chat/channels/#{channel.id}/messages?limit=2&cursor=#{first["meta"]["next_cursor"]}"
        )
        |> json_response(200)

      assert Enum.map(older["data"], & &1["body"]) == ["Message 1"]
    end

    test "is 404 while chat is off", %{conn: conn, admin: admin, member: member} do
      {:ok, _} = SiteSettings.update(%{"chat_enabled" => "false"}, admin)
      assert conn |> authed(member) |> get(~p"/api/v1/chat/channels") |> json_response(404)
    end
  end

  describe "groups" do
    test "lists visible groups, members, joining and leaving", %{
      conn: conn,
      admin: admin,
      member: member
    } do
      {:ok, open} = Groups.create_group(%{name: "readers"}, admin)

      {:ok, open} =
        Groups.update_settings(open, %{visibility: "public", membership: "open"}, admin)

      assert Enum.any?(
               conn |> get(~p"/api/v1/groups") |> json_response(200) |> assert_list("Group"),
               &(&1["name"] == "readers")
             )

      assert conn |> get(~p"/api/v1/groups/#{open.name}") |> json_response(200)

      assert conn
             |> authed(member)
             |> post(~p"/api/v1/groups/#{open.name}/join")
             |> json_response(200)
             |> get_in(["data", "status"]) == "joined"

      assert [%{"username" => username}] =
               conn
               |> get(~p"/api/v1/groups/#{open.name}/members")
               |> json_response(200)
               |> assert_list("GroupMember")

      assert username == member.username

      assert conn
             |> authed(member)
             |> delete(~p"/api/v1/groups/#{open.name}/membership")
             |> response(204)

      assert conn |> get(~p"/api/v1/groups/admin") |> json_response(404)
    end
  end

  describe "search and uploads" do
    test "search answers the page's results", %{conn: conn, thread: thread} do
      results = conn |> get(~p"/api/v1/search?q=think") |> json_response(200)
      assert_schema(results, "SearchResults")
      assert [%{"thread_id" => id}] = results["results"]
      assert id == thread.id
    end

    test "uploads need the uploads:write scope", %{conn: conn, member: member} do
      file = %Plug.Upload{
        path: Path.join(System.tmp_dir!(), "api-test.txt"),
        filename: "api-test.txt",
        content_type: "text/plain"
      }

      File.write!(file.path, "hello")
      on_exit(fn -> File.rm(file.path) end)

      assert conn
             |> authed(member, ["read"])
             |> post(~p"/api/v1/uploads", file: file)
             |> json_response(403)

      assert conn
             |> authed(member, ["uploads:write"])
             |> post(~p"/api/v1/uploads", file: file)
             |> json_response(201)
             |> Map.fetch!("data")
             |> assert_schema("Upload")
    end
  end

  describe "admin" do
    test "site settings are read and written", %{conn: conn, admin: admin, member: member} do
      authed_admin = authed(conn, admin)

      settings =
        authed_admin
        |> get(~p"/api/v1/admin/site-settings")
        |> json_response(200)
        |> Map.fetch!("data")

      Enum.each(settings, &assert_schema(&1, "SiteSetting"))
      assert Enum.any?(settings, &(&1["key"] == "title"))

      assert authed_admin
             |> patch(~p"/api/v1/admin/site-settings", %{"title" => "Renamed forum"})
             |> json_response(200)

      assert SiteSettings.get("title") == "Renamed forum"
      on_exit(fn -> SiteSettings.clear_cache() end)

      assert %{"errors" => %{"api_rate_limit" => [_ | _]}} =
               authed_admin
               |> patch(~p"/api/v1/admin/site-settings", %{"api_rate_limit" => "nope"})
               |> json_response(422)

      assert conn |> authed(member) |> get(~p"/api/v1/admin/site-settings") |> json_response(403)
    end

    test "secrets aren't given out", %{conn: conn, admin: admin} do
      {:ok, _} = SiteSettings.update(%{"akismet_api_key" => "secret-key"}, admin)
      on_exit(fn -> SiteSettings.clear_cache() end)

      settings =
        conn |> authed(admin) |> get(~p"/api/v1/admin/site-settings") |> json_response(200)

      akismet = Enum.find(settings["data"], &(&1["key"] == "akismet_api_key"))
      assert akismet["value"] == "[secret]"
    end

    test "webhooks", %{conn: conn, admin: admin, member: member} do
      authed_admin = authed(conn, admin)

      created =
        authed_admin
        |> post(~p"/api/v1/admin/webhooks", %{
          payload_url: "https://example.com/hook",
          event_types: ["post"]
        })
        |> json_response(201)
        |> Map.fetch!("data")
        |> assert_schema("Webhook")

      assert authed_admin
             |> patch(~p"/api/v1/admin/webhooks/#{created["id"]}", %{active: false})
             |> json_response(200)
             |> get_in(["data", "active"]) == false

      assert authed_admin
             |> get(~p"/api/v1/admin/webhooks")
             |> json_response(200)
             |> assert_list("Webhook")

      assert conn |> authed(member) |> get(~p"/api/v1/admin/webhooks") |> json_response(403)
      assert authed_admin |> delete(~p"/api/v1/admin/webhooks/#{created["id"]}") |> response(204)

      assert %{"errors" => %{"payload_url" => [_ | _]}} =
               authed_admin
               |> post(~p"/api/v1/admin/webhooks", %{payload_url: "not a url"})
               |> json_response(422)
    end

    test "badges, grants and the public listing", %{conn: conn, admin: admin, member: member} do
      authed_admin = authed(conn, admin)

      badge =
        authed_admin
        |> post(~p"/api/v1/admin/badges", %{name: "Helper", description: "Helps"})
        |> json_response(201)
        |> Map.fetch!("data")
        |> assert_schema("Badge")

      assert Enum.any?(
               conn |> get(~p"/api/v1/badges") |> json_response(200) |> assert_list("Badge"),
               &(&1["name"] == "Helper")
             )

      grant =
        authed_admin
        |> post(~p"/api/v1/admin/badges/#{badge["id"]}/grants", %{username: member.username})
        |> json_response(201)
        |> Map.fetch!("data")

      assert grant["user_id"] == member.id

      assert authed_admin
             |> delete(~p"/api/v1/admin/badges/grants/#{grant["id"]}")
             |> response(204)

      assert conn
             |> authed(member)
             |> post(~p"/api/v1/admin/badges", %{name: "Nope"})
             |> json_response(403)

      assert authed_admin |> delete(~p"/api/v1/admin/badges/#{badge["id"]}") |> response(204)
    end

    test "the review queue approves and rejects queued posts", %{
      conn: conn,
      admin: admin,
      member: member,
      thread: thread
    } do
      {:ok, _} = SiteSettings.update(%{"approve_new_user_posts" => "3"}, admin)
      on_exit(fn -> SiteSettings.clear_cache() end)
      newcomer = user_fixture(%{trust_level: 0})
      {:ok, queued} = Discussion.create_post(thread, newcomer, %{body: "Awaiting approval"})

      assert Enum.any?(
               conn
               |> authed(admin)
               |> get(~p"/api/v1/review")
               |> json_response(200)
               |> Map.fetch!("data"),
               &(&1["kind"] == "queued")
             )

      assert conn |> authed(member) |> get(~p"/api/v1/review") |> json_response(403)

      assert conn
             |> authed(admin)
             |> post(~p"/api/v1/review/posts/#{queued.id}/approve")
             |> response(204)

      assert Firefly.Repo.get!(Firefly.Discussion.Post, queued.id).queued_at == nil
    end
  end

  describe "read-only mode" do
    test "writes are 503, reads still work", %{
      conn: conn,
      admin: admin,
      member: member,
      thread: thread
    } do
      :ok = Firefly.Backups.set_read_only("Maintenance", admin)
      on_exit(fn -> Firefly.Backups.set_read_only(nil) end)

      assert conn |> get(~p"/api/v1/threads/#{thread.id}") |> json_response(200)

      refused =
        conn
        |> authed(member)
        |> post(~p"/api/v1/threads/#{thread.id}/posts", %{body: "hi"})

      assert %{"detail" => detail} = json_response(refused, 503)
      assert detail =~ "read-only"
      assert get_resp_header(refused, "retry-after") == ["300"]
    end
  end

  test "the MCP server needs a key with the read scope", %{
    conn: conn,
    admin: admin,
    member: member
  } do
    {:ok, _} = SiteSettings.update(%{"mcp_enabled" => "true"}, admin)
    on_exit(fn -> SiteSettings.clear_cache() end)
    request = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}

    assert conn
           |> put_req_header("content-type", "application/json")
           |> authed(member, ["read"])
           |> post(~p"/mcp", request)
           |> json_response(200)

    assert conn
           |> put_req_header("content-type", "application/json")
           |> authed(member, ["topics:write"])
           |> post(~p"/mcp", request)
           |> json_response(403)
  end
end
