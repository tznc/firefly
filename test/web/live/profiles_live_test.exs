defmodule FirestormWeb.Web.ProfilesLiveTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.{Directory, Forums, Ignores, Solved}

  setup do
    bob = user_fixture(%{username: "bob", bio: nil})
    {:ok, bob} = Forums.update_user(bob, %{bio: "I like **OTP** and long walks."})
    alice = user_fixture(%{username: "alice"})
    category = category_fixture()
    {:ok, category} = Forums.update_category(category, %{allow_accepted_answers: true})
    thread = thread_fixture(category, bob, %{title: "Bob's thread"})
    other = thread_fixture(category, alice, %{title: "Alice's question"})
    {:ok, reply} = Forums.create_post(other, bob, %{body: "Here's the answer"})
    {:ok, _} = Forums.create_post(thread, alice, %{body: "Nice thread"})
    [first] = FirestormWeb.Repo.preload(thread, :posts).posts
    Forums.like_post(first, alice)
    Forums.like_post(reply, alice)
    {:ok, _} = Solved.accept(Forums.get_thread!(other.id), reply, alice)
    :ok = Directory.refresh()

    %{bob: bob, alice: alice, thread: thread, category: category}
  end

  test "the activity stream filters by kind", %{conn: conn, bob: bob} do
    conn
    |> visit(~p"/users/#{bob}")
    |> assert_has("#user-posts article", count: 2)
    |> click_link("#activity-filters a", "Topics")
    |> assert_has("#user-posts article", count: 1)
    |> assert_has("#user-posts", text: "Bob's thread")
    |> click_link("#activity-filters a", "Replies")
    |> assert_has("#user-posts article", count: 1)
    |> assert_has("#user-posts", text: "Alice's question")
    |> click_link("#activity-filters a", "Solved")
    |> assert_has("#user-posts", text: "Here's the answer")
    |> click_link("#activity-filters a", "Likes given")
    |> assert_has("p", text: "Nothing here yet.")
  end

  test "likes given lists the posts the user liked", %{conn: conn, alice: alice} do
    conn
    |> visit(~p"/users/#{alice}?filter=likes")
    |> assert_has("#user-posts article", count: 2)
  end

  test "the summary shows stats and top posts", %{conn: conn, bob: bob} do
    conn
    |> visit(~p"/users/#{bob}")
    |> click_link("Summary")
    |> assert_path(~p"/users/#{bob}/summary")
    |> assert_has(".summary-topic_count", text: "1")
    |> assert_has(".summary-likes_received", text: "2")
    |> assert_has("#top-topics", text: "Bob's thread")
    |> assert_has("#top-replies", text: "Alice's question")
  end

  test "a hidden profile shows only the name and avatar", %{conn: conn, bob: bob} do
    {:ok, bob} = Forums.update_preferences(bob, %{hide_profile: true})

    conn
    |> visit(~p"/users/#{bob}")
    |> assert_has("#profile-hidden", text: "This profile is private.")
    |> refute_has("#user-bio")
    |> refute_has("#user-posts")
    |> refute_has("dt", text: "Joined")

    conn |> visit(~p"/users") |> refute_has("#user-#{bob.id}")

    # Admins still see it.
    conn
    |> log_in_as(admin_fixture())
    |> visit(~p"/users/#{bob}")
    |> assert_has("#user-bio")
  end

  test "the user card opens from a post, and mutes from there", %{
    conn: conn,
    bob: bob,
    alice: alice,
    thread: thread,
    category: category
  } do
    conn
    |> log_in_as(alice)
    |> visit(~p"/categories/#{category}/threads/#{thread}")
    |> click_button("Show @bob's card")
    |> assert_has("#user-card", text: "@bob")
    |> assert_has("#user-card .user-card-bio", text: "I like OTP and long walks.")
    |> assert_has("#user-card", text: "Joined")
    |> assert_has("#user-card a", text: "Message")
    |> within("#user-card", fn session ->
      session
      |> select("How you see @bob", option: "Ignored: also hide their posts")
      |> click_button("Save")
    end)
    |> assert_has("#user-card", text: "@bob is ignored.")
    |> assert_has("#posts .ignored-post")

    assert Ignores.level(alice, bob) == "ignore"
  end

  test "privacy settings save hiding the profile", %{conn: conn, bob: bob} do
    conn
    |> log_in_as(bob)
    |> visit(~p"/settings/privacy")
    |> check("Hide my public profile and presence", exact: false)
    |> click_button("Save")
    |> assert_has("#flash-info", text: "Privacy settings saved.")

    assert Forums.get_user!(bob.id).hide_profile
  end
end
