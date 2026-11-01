defmodule FirestormWeb.MentionsTest do
  use FirestormWeb.DataCase
  use Bamboo.Test, shared: true

  alias FirestormWeb.{Forums, Markdown, Mentions, Notifications}
  alias FirestormWeb.Forums.Subscriptions
  alias FirestormWeb.Web.Paths

  defp user(name) do
    {:ok, user} = Forums.create_user(%{username: name, name: name, email: "#{name}@example.com"})
    user
  end

  # Casts are async; a call to the server waits for them.
  defp flush, do: :sys.get_state(Notifications)

  defp mentions(user), do: Enum.filter(Forums.notifications_for(user), &(&1.kind == "mentioned"))

  describe "rendering" do
    setup do
      {:ok, category} = Forums.create_category(%{title: "Elixir Talk"})
      %{alice: user("Alice"), category: category}
    end

    test "links mentions of existing users and categories, in any case", %{
      alice: alice,
      category: category
    } do
      html = Markdown.render("Hi @alice, see #ELIXIR-talk and @nobody #nothing")

      assert html =~ ~s(<a href="#{Paths.user_url(alice)}" rel="noopener noreferrer">@alice</a>)

      assert html =~
               ~s(<a href="#{Paths.category_url(category)}" rel="noopener noreferrer">#ELIXIR-talk</a>)

      assert html =~ "@nobody #nothing"
    end

    test "leaves code, links, emails and anchors alone" do
      html =
        Markdown.render("""
        `@alice` [@alice](https://example.com) alice@example.com page#elixir-talk

        ```
        @alice
        ```
        """)

      refute html =~ "/users/"
      refute html =~ "/categories/"
    end

    test "links inside emphasis and quotes, without letting markup through", %{alice: alice} do
      html = Markdown.render("> **@alice**<script>alert(1)</script>")
      assert html =~ ~s(<strong><a href="#{Paths.user_url(alice)}")
      refute html =~ "<script>"
    end
  end

  describe "usernames/1 and the cap" do
    test "skips block quotes and repeats" do
      assert Mentions.usernames("@Bob and @bob, @carol\n\n> @dave said") == ["bob", "carol"]
    end

    test "a post may mention at most max_mentions users" do
      author = user("author")
      {:ok, category} = Forums.create_category(%{title: "Elixir"})
      {:ok, thread} = Forums.create_thread(category, author, %{title: "OTP", body: "Hi"})
      many = Enum.map_join(1..(Mentions.max_mentions() + 1), " ", &"@user#{&1}")

      assert {:error, changeset} = Forums.create_post(thread, author, %{body: many})
      assert "can mention at most 10 users" in errors_on(changeset).body

      assert {:error, _} =
               Forums.create_thread(category, author, %{title: "Spam", body: many})
    end
  end

  describe "notifications" do
    setup do
      {:ok, _} = Notifications.start_link()
      {:ok, category} = Forums.create_category(%{title: "Elixir"})
      author = user("author")
      {:ok, thread} = Forums.create_thread(category, author, %{title: "OTP", body: "Cool?"})
      flush()
      %{author: author, bob: user("bob"), carol: user("carol"), thread: thread}
    end

    defp reply(thread, user, body) do
      {:ok, post} = Forums.create_post(thread, user, %{body: body})
      flush()
      post
    end

    test "mentioned users get a notification and an email, the author doesn't", %{
      author: author,
      bob: bob,
      thread: thread
    } do
      reply(thread, author, "Thoughts @bob? (me: @author)")

      assert [notification] = mentions(bob)
      assert notification.subject == ~s(@author mentioned you in "OTP")
      assert notification.emailed_at

      assert_email_delivered_with(
        to: [nil: "bob@example.com"],
        subject: "@author mentioned you on Firefly"
      )

      assert mentions(author) == []
    end

    test "a mention replaces the watcher's new-post notification", %{
      author: author,
      bob: bob,
      thread: thread
    } do
      reply(thread, bob, "I'm in")
      {:ok, _} = Subscriptions.set_thread_level(bob, thread, "watching")
      reply(thread, author, "@bob agreed")

      assert [%{kind: "mentioned"}] = Forums.notifications_for(bob)
    end

    test "users who muted the thread aren't notified", %{author: author, bob: bob, thread: thread} do
      {:ok, _} = Subscriptions.set_thread_level(bob, thread, "muted")
      reply(thread, author, "@bob ?")
      assert Forums.notifications_for(bob) == []
    end

    test "mentions in a new thread notify", %{author: author, bob: bob, thread: thread} do
      {:ok, _} =
        Forums.create_thread(%Forums.Category{id: thread.category_id}, author, %{
          title: "Ping",
          body: "cc @bob"
        })

      flush()
      assert [%{subject: ~s(@author mentioned you in "Ping")}] = mentions(bob)
    end

    test "edits notify only newly mentioned users", %{
      author: author,
      bob: bob,
      carol: carol,
      thread: thread
    } do
      post = reply(thread, author, "@bob look")
      {:ok, post} = Forums.update_post(post, author, %{body: "@bob look, @carol too"})
      flush()
      {:ok, _} = Forums.update_post(post, author, %{body: "@BOB @carol, again"})
      flush()

      assert length(mentions(bob)) == 1
      assert length(mentions(carol)) == 1
    end

    test "quoting a post doesn't re-notify the users it mentioned", %{
      author: author,
      bob: bob,
      thread: thread
    } do
      reply(thread, author, "> [@author said:](/x)\n>\n> hey @bob\n\nquoted")
      assert mentions(bob) == []
    end
  end
end
