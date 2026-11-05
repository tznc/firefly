defmodule Firefly.ForumsTest do
  use Firefly.DataCase, async: false

  alias Firefly.{Accounts, Discussion, Groups, Notifications}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Category, Thread}

  @create_user_attrs %{email: "some email", name: "some name", username: "some username"}
  @update_user_attrs %{
    email: "some updated email",
    name: "some updated name",
    username: "some updated username"
  }
  @invalid_user_attrs %{email: nil, name: nil, username: nil}

  @create_category_attrs %{title: "some title"}
  @update_category_attrs %{title: "some updated title"}
  @invalid_category_attrs %{title: nil}

  @create_thread_attrs %{title: "some title", body: "some body"}
  @update_thread_attrs %{title: "some updated title"}
  @invalid_thread_attrs %{title: nil}

  def fixture(type, attrs \\ %{})

  def fixture(:user, attrs) do
    {:ok, user} = Accounts.create_user(attrs)
    user
  end

  def fixture(:category, attrs) do
    {:ok, category} = Discussion.create_category(attrs)
    category
  end

  def fixture(:thread, category, user, attrs) do
    {:ok, thread} = Discussion.create_thread(category, user, attrs)
    thread
  end

  def fixture(:post, thread, user, attrs) do
    {:ok, post} = Discussion.create_post(thread, user, attrs)
    post
  end

  test "list_users/1 returns all users" do
    user = fixture(:user, @create_user_attrs)
    assert Accounts.list_users() == [user]
  end

  test "get_user! returns the user with given id" do
    user = fixture(:user, @create_user_attrs)
    assert Accounts.get_user!(user.id) == user
  end

  test "create_user/1 with valid data creates a user" do
    assert {:ok, %User{} = user} = Accounts.create_user(@create_user_attrs)
    assert user.email == "some email"
    assert user.name == "some name"
    assert user.username == "some username"
  end

  test "create_user/1 with invalid data returns error changeset" do
    assert {:error, %Ecto.Changeset{}} = Accounts.create_user(@invalid_user_attrs)
  end

  test "update_user/2 with valid data updates the user" do
    user = fixture(:user, @create_user_attrs)
    assert {:ok, user} = Accounts.update_user(user, @update_user_attrs)
    assert %User{} = user
    assert user.email == "some updated email"
    assert user.name == "some updated name"
    assert user.username == "some updated username"
  end

  test "update_user/2 with invalid data returns error changeset" do
    user = fixture(:user, @create_user_attrs)
    assert {:error, %Ecto.Changeset{}} = Accounts.update_user(user, @invalid_user_attrs)
    assert user == Accounts.get_user!(user.id)
  end

  test "delete_user/1 deletes the user" do
    user = fixture(:user, @create_user_attrs)
    assert {:ok, %User{}} = Accounts.delete_user(user)
    assert_raise Ecto.NoResultsError, fn -> Accounts.get_user!(user.id) end
  end

  test "change_user/1 returns a user changeset" do
    user = fixture(:user, @create_user_attrs)
    assert %Ecto.Changeset{} = Accounts.change_user(user)
  end

  describe "admin?" do
    test "returns true for users with an 'admin' role" do
      {:ok, admin} = Groups.create_role("admin")
      {:ok, user} = Accounts.create_user(@create_user_attrs)
      {:ok, _} = Groups.add_role(user, admin)
      assert Accounts.admin?(user)
    end

    test "returns false for users without an 'admin' role" do
      {:ok, _admin} = Groups.create_role("admin")
      {:ok, user} = Accounts.create_user(@create_user_attrs)
      refute Accounts.admin?(user)
    end
  end

  test "list_categories/1 returns all categories" do
    category = fixture(:category, @create_category_attrs)
    assert Discussion.list_categories() == [category]
  end

  test "get_category! returns the category with given id" do
    category = fixture(:category, @create_category_attrs)
    assert Discussion.get_category!(category.id) == category
  end

  test "create_category/1 with valid data creates a category" do
    assert {:ok, %Category{} = category} = Discussion.create_category(@create_category_attrs)
    assert category.title == "some title"
  end

  test "create_category/1 automatically generates a slug" do
    assert {:ok, %Category{} = category} = Discussion.create_category(@create_category_attrs)
    assert category.slug == "some-title"
    assert {:ok, %Category{} = category} = Discussion.create_category(@create_category_attrs)
    assert category.slug == "some-title-1"
  end

  test "create_category/1 with invalid data returns error changeset" do
    assert {:error, %Ecto.Changeset{}} = Discussion.create_category(@invalid_category_attrs)
  end

  test "update_category/2 with valid data updates the category" do
    category = fixture(:category, @create_category_attrs)
    assert {:ok, category} = Discussion.update_category(category, @update_category_attrs)
    assert %Category{} = category
    assert category.title == "some updated title"
  end

  test "update_category/2 with invalid data returns error changeset" do
    category = fixture(:category, @create_category_attrs)

    assert {:error, %Ecto.Changeset{}} =
             Discussion.update_category(category, @invalid_category_attrs)

    assert category == Discussion.get_category!(category.id)
  end

  test "delete_category/1 deletes the category" do
    category = fixture(:category, @create_category_attrs)
    assert {:ok, %Category{}} = Discussion.delete_category(category)
    assert_raise Ecto.NoResultsError, fn -> Discussion.get_category!(category.id) end
  end

  test "change_category/1 returns a category changeset" do
    category = fixture(:category, @create_category_attrs)
    assert %Ecto.Changeset{} = Discussion.change_category(category)
  end

  describe "threads" do
    setup [:create_user, :create_category]

    test "list_threads/1 returns all threads", %{category: category, user: user} do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      expected = [thread.title]

      result =
        category
        |> Discussion.list_threads()
        |> Enum.map(& &1.title)

      assert expected == result
    end

    test "recent_threads/1 returns a category's threads ordered by most recent post", %{
      category: category,
      user: user
    } do
      threads =
        for num <- ~w(First Second Third Fourth Fifth) do
          fixture(:thread, category, user, %{title: "#{num} thread", body: "#{num} thread body"})
        end

      for thread <- threads do
        for n <- [2, 3, 4] do
          fixture(:post, thread, user, %{body: "Post #{n} in #{thread.title}"})
        end
      end

      [thread1, thread2, thread3, thread4, thread5] = threads
      :timer.sleep(1)
      fixture(:post, thread1, user, %{body: "last post in thread1"})
      fixture(:post, thread3, user, %{body: "last post in thread2"})
      fixture(:post, thread5, user, %{body: "last post in thread3"})
      other_category = fixture(:category, %{title: "other category"})

      other_thread =
        fixture(:thread, other_category, user, %{title: "other thread", body: "other thread body"})

      _other_thread_post = fixture(:post, other_thread, user, %{body: "Other thread last post"})

      recent_threads =
        category
        |> Discussion.recent_threads()

      thread_ids =
        recent_threads
        |> Enum.map(& &1.id)

      expected_ids = [thread5.id, thread3.id, thread1.id, thread4.id, thread2.id]
      assert expected_ids == thread_ids
    end

    test "get_thread! returns the thread with given id", %{category: category, user: user} do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      assert Discussion.get_thread!(category, thread.id).title == thread.title
    end

    test "create_thread/2 with valid data creates a thread and its first post", %{
      category: category,
      user: user
    } do
      assert {:ok, %Thread{} = thread} =
               Discussion.create_thread(category, user, @create_thread_attrs)

      assert thread.title == "some title"
      first_post = hd(thread.posts)
      assert first_post.thread_id == thread.id
      assert first_post.body == "some body"
    end

    test "create_thread/1 with invalid data returns error changeset", %{
      category: category,
      user: user
    } do
      assert {:error, %Ecto.Changeset{}} =
               Discussion.create_thread(category, user, @invalid_thread_attrs)
    end

    test "create_thread/2 automatically generates a slug", %{category: category, user: user} do
      assert {:ok, %Thread{} = thread} =
               Discussion.create_thread(category, user, @create_thread_attrs)

      assert thread.slug == "some-title"

      assert {:ok, %Thread{} = thread} =
               Discussion.create_thread(category, user, @create_thread_attrs)

      assert thread.slug == "some-title-1"
    end

    test "update_thread/2 with valid data updates the thread", %{category: category, user: user} do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      assert {:ok, thread} = Discussion.update_thread(thread, @update_thread_attrs)
      assert %Thread{} = thread
      assert thread.title == "some updated title"
    end

    test "update_thread/2 with invalid data returns error changeset", %{
      category: category,
      user: user
    } do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      assert {:error, %Ecto.Changeset{}} = Discussion.update_thread(thread, @invalid_thread_attrs)
      assert thread.title == Discussion.get_thread!(category, thread.id).title
    end

    test "delete_thread/2 deletes a thread that has been viewed and watched", %{
      category: category,
      user: user
    } do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      [post] = Repo.preload(thread, :posts).posts
      {:ok, _} = Discussion.view(user, post)
      {:ok, _} = Notifications.watch(user, thread)

      assert {:ok, %Thread{}} = Discussion.delete_thread(thread, user)
      assert Discussion.get_thread(thread.id) == nil
    end

    test "delete_category/1 deletes the category's threads too", %{
      category: category,
      user: user
    } do
      thread = fixture(:thread, category, user, @create_thread_attrs)

      assert {:ok, %Category{}} = Discussion.delete_category(category)
      assert Discussion.get_thread(thread.id) == nil
    end

    test "delete_thread/2 deletes the thread", %{category: category, user: user} do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      assert {:ok, %Thread{}} = Discussion.delete_thread(thread, user)
      assert_raise Ecto.NoResultsError, fn -> Discussion.get_thread!(category, thread.id) end
    end

    test "change_thread/1 returns a thread changeset", %{category: category, user: user} do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      assert %Ecto.Changeset{} = Discussion.change_thread(thread)
    end
  end

  test "get_user_by_username/1 returns an existing user" do
    user = fixture(:user, @create_user_attrs)
    assert user == Accounts.get_user_by_username(user.username)
  end

  describe "posting in a thread" do
    setup [:create_user, :create_category, :create_thread]

    test "creating a post in a thread", %{thread: thread, user: user} do
      {:ok, post} = Discussion.create_post(thread, user, %{body: "Some body"})
      assert post.thread_id == thread.id
      assert post.user_id == user.id
      assert post.body == "Some body"
    end

    test "creating an invalid post returns an error changeset", %{thread: thread, user: user} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Discussion.create_post(thread, user, %{body: ""})

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "User.avatar_url/2" do
    test "uses Gravatar with an identicon fallback" do
      url =
        Firefly.Accounts.User.avatar_url(
          %User{email: "josh@example.com", username: "knewter"},
          64
        )

      assert url =~ "gravatar.com/avatar/"
      assert url =~ "d=identicon"
      assert url =~ "s=64"
    end

    test "gives users without an email a stable identicon" do
      user = %User{email: nil, username: "knewter"}
      assert Firefly.Accounts.User.avatar_url(user) =~ "d=identicon"

      assert Firefly.Accounts.User.avatar_url(user) ==
               Firefly.Accounts.User.avatar_url(user)

      refute Firefly.Accounts.User.avatar_url(user) =~ "adorable"
    end
  end

  describe "register_user/1" do
    @registration %{username: "newbie", email: "newbie@example.com", password: "s3cret-password"}

    test "registers a user with a hashed password" do
      assert {:ok, user} = Accounts.register_user(@registration)
      assert user.username == "newbie"
      assert user.name == "newbie"
      assert user.email == "newbie@example.com"
      refute user.password_hash == "s3cret-password"
      assert Bcrypt.verify_pass("s3cret-password", user.password_hash)
    end

    test "requires a valid username, email and password" do
      assert {:error, changeset} =
               Accounts.register_user(%{username: "a b", email: "nope", password: "short"})

      errors = errors_on(changeset)
      assert errors.username
      assert errors.email == ["must be a valid email"]
      assert errors.password == ["should be at least 8 character(s)"]
    end

    test "rejects a taken username" do
      {:ok, _} = Accounts.register_user(@registration)

      assert {:error, changeset} =
               Accounts.register_user(%{@registration | email: "other@example.com"})

      assert "has already been taken" in errors_on(changeset).username
    end
  end

  describe "authenticate_by_password/2" do
    setup do
      {:ok, user} =
        Accounts.register_user(%{
          username: "newbie",
          email: "newbie@example.com",
          password: "s3cret-password"
        })

      %{user: user}
    end

    test "logs in with the right password", %{user: %{id: id}} do
      assert {:ok, %{id: ^id}} = Accounts.authenticate_by_password("newbie", "s3cret-password")
    end

    test "rejects a wrong password" do
      assert {:error, _} = Accounts.authenticate_by_password("newbie", "wrong")
    end

    test "never registers an unknown username" do
      assert {:error, _} = Accounts.authenticate_by_password("stranger", "s3cret-password")
      refute Accounts.get_user_by_username("stranger")
    end

    test "rejects a password login for a user without a password (e.g. GitHub users)" do
      _ = fixture(:user, %{username: "octocat", email: "octo@example.com", name: "Octo"})
      assert {:error, _} = Accounts.authenticate_by_password("octocat", "anything")
    end
  end

  describe "watching a thread" do
    setup [:create_user, :create_category, :create_thread]

    test "watching a thread", %{thread: thread, user: user} do
      {:ok, _watch} = user |> Notifications.watch(thread)
      assert thread |> Notifications.watched_by?(user)
    end
  end

  describe "viewing a post" do
    setup [:create_user, :create_category, :create_thread]

    test "viewing a post", %{thread: thread, user: user} do
      thread =
        thread
        |> Repo.preload(:posts)

      [first_post] = thread.posts

      {:ok, _view} = user |> Discussion.view(first_post)
      assert first_post |> Discussion.viewed_by?(user)
    end
  end

  describe "notifications" do
    setup [:create_user, :create_category, :create_thread]

    test "getting a user's notifications when there aren't any", %{user: user} do
      assert [] = Notifications.notifications_for(user)
    end

    test "getting a user's notifications", %{user: user} do
      body = "You are looking dapper today!"

      {:ok, _} =
        Notifications.notify(user, %{
          kind: "silenced",
          subject: "Some subject",
          body: body,
          url: "http://www.slashdot.org"
        })

      [first_notification | _] = Notifications.notifications_for(user)
      assert body == first_notification.body
    end
  end

  def create_category(_) do
    category = fixture(:category, @create_category_attrs)
    {:ok, category: category}
  end

  def create_thread(%{category: category, user: user}) do
    thread = fixture(:thread, category, user, @create_thread_attrs)
    {:ok, thread: thread}
  end

  def create_user(_) do
    user = fixture(:user, @create_user_attrs)
    {:ok, user: user}
  end

  # Found by Firefly.DiscussionPropertyTest: a title that slugifies to
  # nothing (emoji, punctuation) raised (a nil slug was looked up), and
  # Slugify kept control characters in slugs.
  test "every title gets a URL-safe slug" do
    user = Firefly.Fixtures.user_fixture()

    for {title, slug} <- [{"🔥🔥", "untitled"}, {"!!!", "untitled-1"}, {"a\x1Ab", "ab"}] do
      assert {:ok, %{slug: ^slug}} = Firefly.Discussion.create_category(%{title: title})
    end

    {:ok, category} = Firefly.Discussion.create_category(%{title: "Home"})

    assert {:ok, %{slug: "untitled"}} =
             Firefly.Discussion.create_thread(category, user, %{title: "🔥🔥🔥", body: "Hot."})
  end

  # Found by Firefly.DiscussionPropertyTest: a title longer than the column
  # raised instead of failing validation, and a long slug left no room for
  # its "-N" suffix.
  test "category and thread titles are at most 255 characters, and slugs stay short" do
    assert {:error, changeset} =
             Firefly.Discussion.create_category(%{title: String.duplicate("9", 256)})

    assert "should be at most 255 character(s)" in errors_on(changeset).title

    for _ <- 1..2 do
      assert {:ok, category} =
               Firefly.Discussion.create_category(%{title: String.duplicate("9", 255)})

      assert String.length(category.slug) <= 202
    end

    user = Firefly.Fixtures.user_fixture()
    {:ok, home} = Firefly.Discussion.create_category(%{title: "Home"})
    attrs = %{title: String.duplicate("9", 256), body: "Long."}
    assert {:error, changeset} = Firefly.Discussion.create_thread(home, user, attrs)
    assert "should be at most 255 character(s)" in errors_on(changeset).title

    # Counted as Postgres does, by code point: 100 graphemes of a letter
    # and two combining marks are 300 (found by NotificationsPropertyTest).
    zalgo = String.duplicate("e\u0301\u0308", 100)
    assert {:error, changeset} = Firefly.Discussion.create_category(%{title: zalgo})
    assert errors_on(changeset).title != []
    attrs = %{title: zalgo, body: "Long."}
    assert {:error, changeset} = Firefly.Discussion.create_thread(home, user, attrs)
    assert errors_on(changeset).title != []
  end
end
