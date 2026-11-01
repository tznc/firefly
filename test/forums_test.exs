defmodule FirestormWeb.ForumsTest do
  use FirestormWeb.DataCase, async: false

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.{User, Category, Thread}

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
    {:ok, user} = Forums.create_user(attrs)
    user
  end

  def fixture(:category, attrs) do
    {:ok, category} = Forums.create_category(attrs)
    category
  end

  def fixture(:thread, category, user, attrs) do
    {:ok, thread} = Forums.create_thread(category, user, attrs)
    thread
  end

  def fixture(:post, thread, user, attrs) do
    {:ok, post} = Forums.create_post(thread, user, attrs)
    post
  end

  test "list_users/1 returns all users" do
    user = fixture(:user, @create_user_attrs)
    assert Forums.list_users() == [user]
  end

  test "get_user! returns the user with given id" do
    user = fixture(:user, @create_user_attrs)
    assert Forums.get_user!(user.id) == user
  end

  test "create_user/1 with valid data creates a user" do
    assert {:ok, %User{} = user} = Forums.create_user(@create_user_attrs)
    assert user.email == "some email"
    assert user.name == "some name"
    assert user.username == "some username"
  end

  test "create_user/1 with invalid data returns error changeset" do
    assert {:error, %Ecto.Changeset{}} = Forums.create_user(@invalid_user_attrs)
  end

  test "update_user/2 with valid data updates the user" do
    user = fixture(:user, @create_user_attrs)
    assert {:ok, user} = Forums.update_user(user, @update_user_attrs)
    assert %User{} = user
    assert user.email == "some updated email"
    assert user.name == "some updated name"
    assert user.username == "some updated username"
  end

  test "update_user/2 with invalid data returns error changeset" do
    user = fixture(:user, @create_user_attrs)
    assert {:error, %Ecto.Changeset{}} = Forums.update_user(user, @invalid_user_attrs)
    assert user == Forums.get_user!(user.id)
  end

  test "delete_user/1 deletes the user" do
    user = fixture(:user, @create_user_attrs)
    assert {:ok, %User{}} = Forums.delete_user(user)
    assert_raise Ecto.NoResultsError, fn -> Forums.get_user!(user.id) end
  end

  test "change_user/1 returns a user changeset" do
    user = fixture(:user, @create_user_attrs)
    assert %Ecto.Changeset{} = Forums.change_user(user)
  end

  describe "admin?" do
    test "returns true for users with an 'admin' role" do
      {:ok, admin} = Forums.create_role("admin")
      {:ok, user} = Forums.create_user(@create_user_attrs)
      {:ok, _} = Forums.add_role(user, admin)
      assert Forums.admin?(user)
    end

    test "returns false for users without an 'admin' role" do
      {:ok, _admin} = Forums.create_role("admin")
      {:ok, user} = Forums.create_user(@create_user_attrs)
      refute Forums.admin?(user)
    end
  end

  test "list_categories/1 returns all categories" do
    category = fixture(:category, @create_category_attrs)
    assert Forums.list_categories() == [category]
  end

  test "get_category! returns the category with given id" do
    category = fixture(:category, @create_category_attrs)
    assert Forums.get_category!(category.id) == category
  end

  test "create_category/1 with valid data creates a category" do
    assert {:ok, %Category{} = category} = Forums.create_category(@create_category_attrs)
    assert category.title == "some title"
  end

  test "create_category/1 automatically generates a slug" do
    assert {:ok, %Category{} = category} = Forums.create_category(@create_category_attrs)
    assert category.slug == "some-title"
    assert {:ok, %Category{} = category} = Forums.create_category(@create_category_attrs)
    assert category.slug == "some-title-1"
  end

  test "create_category/1 with invalid data returns error changeset" do
    assert {:error, %Ecto.Changeset{}} = Forums.create_category(@invalid_category_attrs)
  end

  test "update_category/2 with valid data updates the category" do
    category = fixture(:category, @create_category_attrs)
    assert {:ok, category} = Forums.update_category(category, @update_category_attrs)
    assert %Category{} = category
    assert category.title == "some updated title"
  end

  test "update_category/2 with invalid data returns error changeset" do
    category = fixture(:category, @create_category_attrs)
    assert {:error, %Ecto.Changeset{}} = Forums.update_category(category, @invalid_category_attrs)
    assert category == Forums.get_category!(category.id)
  end

  test "delete_category/1 deletes the category" do
    category = fixture(:category, @create_category_attrs)
    assert {:ok, %Category{}} = Forums.delete_category(category)
    assert_raise Ecto.NoResultsError, fn -> Forums.get_category!(category.id) end
  end

  test "change_category/1 returns a category changeset" do
    category = fixture(:category, @create_category_attrs)
    assert %Ecto.Changeset{} = Forums.change_category(category)
  end

  describe "threads" do
    setup [:create_user, :create_category]

    test "list_threads/1 returns all threads", %{category: category, user: user} do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      expected = [thread.title]

      result =
        category
        |> Forums.list_threads()
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
        |> Forums.recent_threads()

      thread_ids =
        recent_threads
        |> Enum.map(& &1.id)

      expected_ids = [thread5.id, thread3.id, thread1.id, thread4.id, thread2.id]
      assert expected_ids == thread_ids
    end

    test "get_thread! returns the thread with given id", %{category: category, user: user} do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      assert Forums.get_thread!(category, thread.id).title == thread.title
    end

    test "create_thread/2 with valid data creates a thread and its first post", %{
      category: category,
      user: user
    } do
      assert {:ok, %Thread{} = thread} =
               Forums.create_thread(category, user, @create_thread_attrs)

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
               Forums.create_thread(category, user, @invalid_thread_attrs)
    end

    test "create_thread/2 automatically generates a slug", %{category: category, user: user} do
      assert {:ok, %Thread{} = thread} =
               Forums.create_thread(category, user, @create_thread_attrs)

      assert thread.slug == "some-title"

      assert {:ok, %Thread{} = thread} =
               Forums.create_thread(category, user, @create_thread_attrs)

      assert thread.slug == "some-title-1"
    end

    test "update_thread/2 with valid data updates the thread", %{category: category, user: user} do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      assert {:ok, thread} = Forums.update_thread(thread, @update_thread_attrs)
      assert %Thread{} = thread
      assert thread.title == "some updated title"
    end

    test "update_thread/2 with invalid data returns error changeset", %{
      category: category,
      user: user
    } do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      assert {:error, %Ecto.Changeset{}} = Forums.update_thread(thread, @invalid_thread_attrs)
      assert thread.title == Forums.get_thread!(category, thread.id).title
    end

    test "delete_thread/1 deletes a thread that has been viewed and watched", %{
      category: category,
      user: user
    } do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      [post] = Repo.preload(thread, :posts).posts
      {:ok, _} = Forums.view(user, post)
      {:ok, _} = Forums.watch(user, thread)

      assert {:ok, %Thread{}} = Forums.delete_thread(thread)
      assert Forums.get_thread(thread.id) == nil
    end

    test "delete_category/1 deletes the category's threads too", %{
      category: category,
      user: user
    } do
      thread = fixture(:thread, category, user, @create_thread_attrs)

      assert {:ok, %Category{}} = Forums.delete_category(category)
      assert Forums.get_thread(thread.id) == nil
    end

    test "delete_thread/1 deletes the thread", %{category: category, user: user} do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      assert {:ok, %Thread{}} = Forums.delete_thread(thread)
      assert_raise Ecto.NoResultsError, fn -> Forums.get_thread!(category, thread.id) end
    end

    test "change_thread/1 returns a thread changeset", %{category: category, user: user} do
      thread = fixture(:thread, category, user, @create_thread_attrs)
      assert %Ecto.Changeset{} = Forums.change_thread(thread)
    end
  end

  test "get_user_by_username/1 returns an existing user" do
    user = fixture(:user, @create_user_attrs)
    assert user == Forums.get_user_by_username(user.username)
  end

  describe "login_or_register_from_github/1" do
    @github %{uid: 1001, name: "Josh Adams", nickname: "knewter", email: "josh@example.com"}

    test "creates a user linked to the GitHub account id" do
      assert {:ok, user} = Forums.login_or_register_from_github(@github)
      assert user.email == "josh@example.com"
      assert user.username == "knewter"
      assert user.github_uid == "1001"
    end

    test "fills in a missing name and email" do
      assert {:ok, user} =
               Forums.login_or_register_from_github(%{@github | name: nil, email: nil})

      assert user.name == "knewter"
      assert user.email == "knewter@users.noreply.github.com"
    end

    test "logs the same GitHub account into the same user, even after a rename" do
      {:ok, %{id: id}} = Forums.login_or_register_from_github(@github)

      assert {:ok, %{id: ^id}} = Forums.login_or_register_from_github(@github)

      assert {:ok, %{id: ^id}} =
               Forums.login_or_register_from_github(%{@github | nickname: "renamed"})
    end

    test "never logs a GitHub user into a password account with the same username" do
      {:ok, victim} =
        Forums.login_or_register_from_identity(%{
          username: "knewter",
          password: "s3cret-password"
        })

      assert {:ok, attacker} = Forums.login_or_register_from_github(@github)
      refute attacker.id == victim.id
      assert attacker.username == "knewter-1"
    end

    test "never logs a different GitHub account into an existing GitHub user" do
      {:ok, first} = Forums.login_or_register_from_github(@github)

      assert {:ok, other} = Forums.login_or_register_from_github(%{@github | uid: 2002})
      refute other.id == first.id
    end

    test "links a pre-existing GitHub-created account only when the email matches" do
      {:ok, legacy} =
        Forums.create_user(%{username: "knewter", name: "Josh", email: "josh@example.com"})

      assert {:ok, %{id: id, github_uid: "1001"}} = Forums.login_or_register_from_github(@github)
      assert id == legacy.id

      {:ok, other_legacy} =
        Forums.create_user(%{username: "octo", name: "Octo", email: "octo@example.com"})

      assert {:ok, impostor} =
               Forums.login_or_register_from_github(%{
                 uid: 3003,
                 nickname: "octo",
                 name: "X",
                 email: "x@example.com"
               })

      refute impostor.id == other_legacy.id
    end

    test "requires a GitHub account id" do
      assert {:error, _} = Forums.login_or_register_from_github(Map.delete(@github, :uid))
    end
  end

  describe "posting in a thread" do
    setup [:create_user, :create_category, :create_thread]

    test "creating a post in a thread", %{thread: thread, user: user} do
      {:ok, post} = Forums.create_post(thread, user, %{body: "Some body"})
      assert post.thread_id == thread.id
      assert post.user_id == user.id
      assert post.body == "Some body"
    end

    test "creating an invalid post returns an error changeset", %{thread: thread, user: user} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Forums.create_post(thread, user, %{body: ""})

      assert %{body: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "User.avatar_url/2" do
    test "uses Gravatar with an identicon fallback" do
      url =
        FirestormWeb.Forums.User.avatar_url(
          %User{email: "josh@example.com", username: "knewter"},
          64
        )

      assert url =~ "gravatar.com/avatar/"
      assert url =~ "d=identicon"
      assert url =~ "s=64"
    end

    test "gives users without an email a stable identicon" do
      user = %User{email: nil, username: "knewter"}
      assert FirestormWeb.Forums.User.avatar_url(user) =~ "d=identicon"

      assert FirestormWeb.Forums.User.avatar_url(user) ==
               FirestormWeb.Forums.User.avatar_url(user)

      refute FirestormWeb.Forums.User.avatar_url(user) =~ "adorable"
    end
  end

  describe "login_or_register_from_identity/1" do
    test "registers a new user with a hashed password" do
      assert {:ok, user} =
               Forums.login_or_register_from_identity(%{
                 username: "newbie",
                 password: "s3cret-password"
               })

      assert user.username == "newbie"
      assert is_binary(user.password_hash)
      refute user.password_hash == "s3cret-password"
      assert Bcrypt.verify_pass("s3cret-password", user.password_hash)
    end

    test "logs in an existing user with the right password" do
      {:ok, %{id: id}} =
        Forums.login_or_register_from_identity(%{username: "newbie", password: "s3cret-password"})

      assert {:ok, %{id: ^id}} =
               Forums.login_or_register_from_identity(%{
                 username: "newbie",
                 password: "s3cret-password"
               })
    end

    test "rejects an existing user with the wrong password" do
      {:ok, _} =
        Forums.login_or_register_from_identity(%{username: "newbie", password: "s3cret-password"})

      assert {:error, _} =
               Forums.login_or_register_from_identity(%{username: "newbie", password: "wrong"})
    end

    test "rejects a password login for a user without a password (e.g. GitHub users)" do
      _ = fixture(:user, %{username: "octocat", email: "octo@example.com", name: "Octo"})

      assert {:error, _} =
               Forums.login_or_register_from_identity(%{
                 username: "octocat",
                 password: "anything"
               })
    end
  end

  describe "watching a thread" do
    setup [:create_user, :create_category, :create_thread]

    test "watching a thread", %{thread: thread, user: user} do
      {:ok, _watch} = user |> Forums.watch(thread)
      assert thread |> Forums.watched_by?(user)
    end
  end

  describe "viewing a post" do
    setup [:create_user, :create_category, :create_thread]

    test "viewing a post", %{thread: thread, user: user} do
      thread =
        thread
        |> Repo.preload(:posts)

      [first_post] = thread.posts

      {:ok, _view} = user |> Forums.view(first_post)
      assert first_post |> Forums.viewed_by?(user)
    end
  end

  describe "notifications" do
    setup [:create_user, :create_category, :create_thread]

    test "getting a user's notifications when there aren't any", %{user: user} do
      assert [] = Forums.notifications_for(user)
    end

    test "getting a user's notifications", %{user: user} do
      body = "You are looking dapper today!"

      {:ok, _} =
        Forums.notify(user, %{subject: "Some subject", body: body, url: "http://www.slashdot.org"})

      [first_notification | _] = Forums.notifications_for(user)
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
end
