defmodule FirestormWeb.Forums do
  @moduledoc """
  The boundary for the Forums system.
  """

  defdelegate authorize(action, user, params), to: FirestormWeb.Forums.Policy
  import Ecto.{Query, Changeset}, warn: false
  alias FirestormWeb.{Repo, Notifications}
  alias FirestormWeb.Web.Endpoint
  alias FirestormWeb.Store.ReplenishResponse

  alias FirestormWeb.Forums.{
    User,
    Category,
    Thread,
    Post,
    Watch,
    View,
    Notification,
    OembedExtractor,
    Role,
    RoleMembership
  }

  @doc """
  Returns the list of users.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users do
    Repo.all(User)
  end

  def paginate_users(page) do
    User
    |> order_by([p], desc: p.inserted_at)
    |> Repo.paginate(page: page)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  @doc """
  Gets a single user, or nil if it does not exist.
  """
  def get_user(id), do: Repo.get(User, id)

  @doc """
  Gets a single user by username. Maybe.
  """
  def get_user_by_username(username), do: Repo.get_by(User, %{username: username})

  @doc """
  Gets a single user by api_token. Maybe.
  """
  def get_user_by_api_token(api_token), do: Repo.get_by(User, %{api_token: api_token})

  @doc """
  Gets a single user by email address. Maybe.
  """
  def get_user_by_email(email), do: Repo.get_by(User, %{email: email})

  @doc """
  Creates a user.

  ## Examples

      iex> create_user(%{field: value})
      {:ok, %User{}}

      iex> create_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user(attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put(:api_token, generate_api_token())

    # Accounts created directly (admin, legacy GitHub logins) are trusted.
    %User{confirmed_at: DateTime.utc_now(:second)}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Registers a user with a username, email and password.

      iex> register_user(%{username: "ada", email: "ada@example.com", password: "s3cret-password"})
      {:ok, %User{}}
  """
  def register_user(attrs) do
    # Unconfirmed until they follow the emailed link (see EmailConfirmation).
    %User{api_token: generate_api_token()}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc "A changeset for the registration form."
  def change_registration(%User{} = user \\ %User{}, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  @doc """
  Updates a user.

  ## Examples

      iex> update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  @doc "Users with a password whose email matches (case-insensitively)."
  def list_password_users_by_email(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    User
    |> where([u], fragment("lower(?)", u.email) == ^email and not is_nil(u.password_hash))
    |> Repo.all()
  end

  @doc """
  Sets a new password from a reset link. Following the emailed link proves the
  address, so it also confirms the email.
  """
  def reset_user_password(%User{} = user, attrs) do
    changeset = User.password_changeset(user, attrs)

    changeset =
      if User.confirmed?(user),
        do: changeset,
        else: Ecto.Changeset.put_change(changeset, :confirmed_at, DateTime.utc_now(:second))

    Repo.update(changeset)
  end

  @doc "Marks the user's email address as confirmed."
  def confirm_user(%User{} = user) do
    if User.confirmed?(user),
      do: {:ok, user},
      else: user |> User.confirm_changeset() |> Repo.update()
  end

  @doc """
  Deletes a User.

  ## Examples

      iex> delete_user(user)
      {:ok, %User{}}

      iex> delete_user(user)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{source: %User{}}

  """
  def change_user(%User{} = user) do
    User.changeset(user, %{})
  end

  @doc """
  Returns the list of categories.

  ## Examples

      iex> list_categories()
      [%Category{}, ...]

  """
  def list_categories do
    Category
    |> order_by(asc: :slug)
    |> Repo.all()
  end

  @doc """
  Takes a list of categories and returns them as well as a map of category ids to recent threads.
  """
  def get_recent_threads_for_categories(categories, user) do
    threads =
      Thread
      |> join(
        :left_lateral,
        [t],
        p in fragment(
          "SELECT thread_id, inserted_at FROM forums_posts WHERE forums_posts.thread_id = ? ORDER BY forums_posts.inserted_at DESC LIMIT 1",
          t.id
        ),
        on: true
      )
      |> order_by([t, p], desc: p.inserted_at)
      |> where([t, p], t.category_id in ^Enum.map(categories, & &1.id))
      |> limit(3)
      |> select([t], t)
      |> Repo.all()
      |> Repo.preload(posts: from(p in Post, order_by: p.inserted_at, preload: :user))
      |> decorate_threads(user)

    initial_threads_map =
      for category <- categories, into: %{} do
        {category.id, []}
      end

    threads_map =
      threads
      |> Enum.reduce(initial_threads_map, fn thread, acc ->
        Map.update(acc, thread.category_id, [thread], fn cat_threads ->
          cat_threads ++ [thread]
        end)
      end)

    {categories, threads_map}
  end

  @doc """
  Gets a single category.

  Raises `Ecto.NoResultsError` if the Category does not exist.

  ## Examples

      iex> get_category!(123)
      %Category{}

      iex> get_category!(456)
      ** (Ecto.NoResultsError)

  """
  def get_category!(id), do: Repo.get!(Category, id)

  @doc """
  Creates a category.

  ## Examples

      iex> create_category(%{title: "Elixir"})
      {:ok, %Category{}}

      iex> create_category(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_category(attrs \\ %{}) do
    %Category{}
    |> Category.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(&broadcast("forums:categories", {:category_created, &1}))
  end

  @doc """
  Updates a category.

  ## Examples

      iex> update_category(category, %{field: new_value})
      {:ok, %Category{}}

      iex> update_category(category, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_category(%Category{} = category, attrs) do
    category
    |> Category.changeset(attrs)
    |> Repo.update()
    |> tap_ok(&broadcast("forums:categories", {:category_updated, &1}))
  end

  @doc """
  Deletes a Category.

  ## Examples

      iex> delete_category(category)
      {:ok, %Category{}}

      iex> delete_category(category)
      {:error, %Ecto.Changeset{}}

  """
  def delete_category(%Category{} = category) do
    category
    |> Repo.delete()
    |> tap_ok(&broadcast("forums:categories", {:category_deleted, &1}))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking category changes.

  ## Examples

      iex> change_category(category)
      %Ecto.Changeset{source: %Category{}}

  """
  def change_category(%Category{} = category) do
    Category.changeset(category, %{})
  end

  @doc """
  Returns the list of threads for a given category. If provided a user, will
  determine whether each thread has been completely read or not.

  ## Examples

      iex> list_threads(category)
      [%Thread{}, ...]

  """
  def list_threads(category, user \\ nil) do
    Thread
    |> where([t], t.category_id == ^category.id)
    |> preload(posts: :user)
    |> Repo.all()
    |> decorate_threads(user)
  end

  @doc """
  Returns the threads in a given category ordered by those with the most recent
  posts. If provided a user, will determine whether each thread has been
  completely read or not.

  ## Examples

      iex> recent_threads(category)
      [%Thread{}, ...]

  """
  def recent_threads(category, user \\ nil) do
    Thread
    |> join(
      :left_lateral,
      [t],
      p in fragment(
        "SELECT thread_id, inserted_at FROM forums_posts WHERE forums_posts.thread_id = ? ORDER BY forums_posts.inserted_at DESC LIMIT 1",
        t.id
      ),
      on: true
    )
    |> order_by([t, p], desc: p.inserted_at)
    |> where(category_id: ^category.id)
    |> select([t], t)
    |> Repo.all()
    |> Repo.preload(posts: from(p in Post, order_by: p.inserted_at, preload: :user))
    |> decorate_threads(user)
  end

  # Decorate a list of threads with:
  # - first_post
  # - posts_count
  # - completely_read?
  defp decorate_threads(threads, user) do
    threads
    |> Enum.map(fn thread ->
      first_post = Enum.at(thread.posts, 0)
      posts_count = length(thread.posts)

      %{
        thread
        | first_post: first_post,
          posts_count: posts_count,
          completely_read?: completely_read?(thread, user)
      }
    end)
  end

  defp completely_read?(_thread, nil), do: false

  defp completely_read?(thread, user) do
    # FIXME: This is insanely inefficient, lol?
    Enum.all?(thread.posts, &viewed_by?(&1, user))
  end

  @doc """
  Gets a single thread in a category.

  Raises `Ecto.NoResultsError` if the Thread does not exist in that category.

  ## Examples

      iex> get_thread!(category, 123)
      %Thread{}

      iex> get_thread!(category, 456)
      ** (Ecto.NoResultsError)

  """
  def get_thread!(category, id) do
    Thread
    |> where([t], t.category_id == ^category.id)
    |> Repo.get!(id)
  end

  @doc "The id of the user who started `thread` (the author of its first post)."
  def thread_author_id(%Thread{id: thread_id}) do
    Post
    |> where([p], p.thread_id == ^thread_id)
    |> order_by([p], asc: p.inserted_at, asc: p.id)
    |> limit(1)
    |> select([p], p.user_id)
    |> Repo.one()
  end

  @doc """
  Gets a thread by id.

  Maybe returns a thread.
  """
  def get_thread(id) do
    Thread
    |> Repo.get(id)
  end

  @doc """
  Gets a thread by id

  Raises `Ecto.NoResultsError` if the Thread does not exist.

  ## Examples

      iex> get_thread!(123)
      %Thread{}

      iex> get_thread!(456)
      ** (Ecto.NoResultsError)

  """
  def get_thread!(id) do
    Thread
    |> Repo.get!(id)
  end

  @doc """
  Gets a post by id

  Raises `Ecto.NoResultsError` if the Post does not exist.

  ## Examples

      iex> get_post!(123)
      %Post{}

      iex> get_post!(456)
      ** (Ecto.NoResultsError)

  """
  def get_post!(id) do
    Post
    |> Repo.get!(id)
  end

  @doc """
  Creates a thread.

  ## Examples

      iex> create_thread(category, user, %{title: "OTP is cool", body: "don't you think?"})
      {:ok, %Thread{}}

      iex> create_thread(category, user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_thread(category, user, attrs \\ %{}) do
    post_attrs =
      attrs
      |> Map.take([:body])
      |> Map.put(:user_id, user.id)

    thread_attrs =
      attrs
      |> Map.take([:title])
      |> Map.put(:category_id, category.id)

    thread_result =
      %{thread: thread_attrs, post: post_attrs}
      |> Thread.new_changeset()
      |> Repo.insert()

    case thread_result do
      {:ok, thread} ->
        thread =
          thread
          |> Repo.preload([:category, posts: [:user]])

        [thread] =
          [thread]
          |> decorate_threads(nil)

        {posts, users} =
          case thread.first_post do
            nil -> {[], []}
            post -> {[post], [post.user]}
          end

        payload = %ReplenishResponse{
          categories: [thread.category],
          threads: [thread],
          users: users,
          posts: posts
        }

        :ok = Endpoint.broadcast!("categories:#{thread.category_id}", "update", payload)
        broadcast_thread(:thread_created, thread)
        {:ok, thread}

      e ->
        e
    end
  end

  @doc """
  Updates a thread.

  ## Examples

      iex> update_thread(thread, %{field: new_value})
      {:ok, %Thread{}}

      iex> update_thread(thread, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_thread(%Thread{} = thread, attrs) do
    thread
    |> Thread.changeset(attrs)
    |> Repo.update()
    |> tap_ok(&broadcast_thread(:thread_updated, &1))
  end

  @doc """
  Deletes a Thread.

  ## Examples

      iex> delete_thread(thread)
      {:ok, %Thread{}}

      iex> delete_thread(thread)
      {:error, %Ecto.Changeset{}}

  """
  def delete_thread(%Thread{} = thread) do
    thread
    |> Repo.delete()
    |> tap_ok(&broadcast_thread(:thread_deleted, &1))
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking thread changes.

  ## Examples

      iex> change_thread(thread)
      %Ecto.Changeset{source: %Thread{}}

  """
  def change_thread(%Thread{} = thread) do
    thread
    |> Repo.preload(:posts)
    |> Thread.changeset(%{})
    |> put_assoc(:posts, thread.posts)
  end

  @doc """
  Logs in (or registers) a GitHub user, identified by GitHub's immutable user
  id (`uid`). Accounts are never matched by username alone: anyone can take a
  GitHub username that matches a local account.

  For accounts created by GitHub logins before ids were stored, the account is
  linked only if it has no password and the GitHub email matches its email.
  New accounts get the GitHub username, or a suffixed one if it is taken.
  """
  def login_or_register_from_github(%{uid: uid} = info) when not is_nil(uid) do
    uid = to_string(uid)
    nickname = info[:nickname]
    name = info[:name] || nickname
    email = info[:email] || "#{nickname}@users.noreply.github.com"

    case Repo.get_by(User, github_uid: uid) do
      %User{} = user -> {:ok, user}
      nil -> link_or_register_github_user(uid, nickname, name, email)
    end
  end

  def login_or_register_from_github(_info), do: {:error, "GitHub did not return an account id."}

  # Links a legacy GitHub-created account (no password, no stored id) only when
  # its email matches GitHub's; anything else gets a new account.
  defp link_or_register_github_user(uid, nickname, name, email) do
    case get_user_by_username(nickname) do
      %User{github_uid: nil, password_hash: nil, email: user_email} = user
      when is_binary(user_email) ->
        if String.downcase(user_email) == String.downcase(email),
          do: user |> User.github_changeset(%{github_uid: uid}) |> Repo.update(),
          else: register_github_user(uid, nickname, name, email)

      _taken_or_free ->
        register_github_user(uid, nickname, name, email)
    end
  end

  defp register_github_user(uid, nickname, name, email) do
    # GitHub vouches for the account; its email is not used to log in.
    %User{confirmed_at: DateTime.utc_now(:second)}
    |> User.github_changeset(%{
      github_uid: uid,
      username: available_username(nickname),
      name: name,
      email: email,
      api_token: generate_api_token()
    })
    |> Repo.insert()
  end

  defp available_username(nickname, attempt \\ 0) do
    candidate = if attempt == 0, do: nickname, else: "#{nickname}-#{attempt}"

    if get_user_by_username(candidate),
      do: available_username(nickname, attempt + 1),
      else: candidate
  end

  @doc """
  Logs in with a username and password. Unknown usernames and accounts
  without a password (e.g. GitHub logins) fail the same way as a wrong
  password.
  """
  def authenticate_by_password(username, password)
      when is_binary(username) and is_binary(password) do
    case get_user_by_username(username) do
      %User{password_hash: hash} = user when is_binary(hash) ->
        if Bcrypt.verify_pass(password, hash), do: {:ok, user}, else: login_error()

      _ ->
        Bcrypt.no_user_verify()
        login_error()
    end
  end

  def authenticate_by_password(_username, _password), do: login_error()

  defp login_error, do: {:error, "No user found with that username or password"}

  @doc """
  Creates a post within a thread.

  ## Examples

      iex> create_post(thread, user, %{body: "don't you think?"})
      {:ok, %Post{}}

      iex> create_post(thread, user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  # NOTE: This obviously doesn't need to use `with` if I'm not using the
  # else...whatever
  def create_post(%Thread{} = thread, %User{} = user, attrs) do
    attrs =
      attrs
      |> Map.put(:thread_id, thread.id)
      |> Map.put(:user_id, user.id)

    with {:ok, post} <- Repo.insert(Post.changeset(%Post{}, attrs)) do
      :ok = Notifications.post_created(post)

      post = Repo.preload(post, [:thread, :user])

      payload = %ReplenishResponse{
        categories: [],
        threads: [post.thread],
        users: [post.user],
        posts: [post]
      }

      :ok = Endpoint.broadcast!("threads:#{post.thread_id}", "update", payload)
      broadcast("forums:thread:#{post.thread_id}", {:post_created, post})
      broadcast_thread(:thread_activity, post.thread)
      {:ok, post}
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking post changes.

  ## Examples

      iex> change_post(post)
      %Ecto.Changeset{source: %Post{}}

  """
  def change_post(%Post{} = post) do
    post
    |> Post.changeset(%{})
  end

  def user_posts(user, %{page: page}) do
    Post
    |> where([p], p.user_id == ^user.id)
    |> order_by([p], desc: p.inserted_at)
    |> preload([p], thread: [:category], user: [])
    |> Repo.paginate(page: page)
  end

  def user_last_post(user) do
    Post
    |> where([p], p.user_id == ^user.id)
    |> order_by([p], desc: p.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  # FIXME: Should track when users log in rather than proxying that by
  # pretending them making a view always happens when they're on the site.
  def user_last_seen(user) do
    "forums_posts_views"
    |> where([v], v.user_id == ^user.id)
    |> order_by([v], desc: v.inserted_at)
    |> select([v], v.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Have a user watch a thread:

      iex> %User{} |> watch(%Thread{})
      {:ok, %Watch{}}

  """
  def watch(%User{} = user, %Thread{} = thread) do
    thread
    |> Ecto.build_assoc(:watches, %{user_id: user.id})
    |> Watch.changeset(%{})
    |> Repo.insert()
  end

  @doc """
  Ensure a user no longer watches a thread:

      iex> %User{} |> unwatch(%Thread{})
      :ok

  """
  def unwatch(%User{} = user, %Thread{} = thread) do
    "forums_threads_watches"
    |> where(assoc_id: ^thread.id)
    |> where(user_id: ^user.id)
    |> Repo.delete_all()

    :ok
  end

  @doc """
  Determine if a user is watching a given watchable (Thread, etc):

      iex> %Thread{} |> watched_by?(%User{})
      false

  """
  def watched_by?(watchable, %User{} = user) do
    watch_count(watchable, user) > 0
  end

  def watcher_ids(watchable) do
    watchable
    |> watches()
    |> select([f], f.user_id)
    |> Repo.all()
  end

  def watch_count(watchable) do
    watchable
    |> watches()
    |> Repo.aggregate(:count, :id)
  end

  defp watch_count(watchable, %User{} = user) do
    watchable
    |> watches()
    |> where([f], f.user_id == ^user.id)
    |> Repo.aggregate(:count, :id)
  end

  defp watches(watchable) do
    watchable
    |> Ecto.assoc(:watches)
  end

  def home_threads(user_or_nil) do
    Thread
    |> join(
      :left_lateral,
      [t],
      p in fragment(
        "SELECT thread_id, inserted_at FROM forums_posts WHERE forums_posts.thread_id = ? ORDER BY forums_posts.inserted_at DESC LIMIT 1",
        t.id
      ),
      on: true
    )
    |> order_by([t, p], desc: p.inserted_at)
    |> select([t], t)
    |> Repo.all()
    |> Repo.preload(posts: from(p in Post, order_by: p.inserted_at, preload: :user))
    |> Repo.preload(:category)
    |> decorate_threads(user_or_nil)
  end

  def watched_threads(%User{} = user) do
    "forums_threads_watches"
    |> where([w], w.user_id == ^user.id)
    |> select([w], w.assoc_id)
    |> Repo.all()
    |> get_decorated_threads(user)
  end

  def participating_threads(%User{} = user) do
    Post
    |> where([p], p.user_id == ^user.id)
    |> select([p], p.thread_id)
    |> Repo.all()
    |> get_decorated_threads(user)
  end

  defp get_decorated_threads(thread_ids, user) do
    Thread
    |> join(
      :left_lateral,
      [t],
      p in fragment(
        "SELECT thread_id, inserted_at FROM forums_posts WHERE forums_posts.thread_id = ? ORDER BY forums_posts.inserted_at DESC LIMIT 1",
        t.id
      ),
      on: true
    )
    |> where([t], t.id in ^thread_ids)
    |> order_by([t, p], desc: p.inserted_at)
    |> preload(category: [], posts: [:user])
    |> Repo.all()
    |> decorate_threads(user)
  end

  @doc """
  Indicate a user viewed a post:

      iex> %User{} |> view(%Post{})
      {:ok, %Post{}}

  """
  def view(%User{} = user, %Post{} = post) do
    post
    |> Ecto.build_assoc(:views, %{user_id: user.id})
    |> View.changeset(%{})
    |> Repo.insert()
  end

  @doc """
  Determine if a user has viewed a given viewable (Post, etc):

      iex> %Post{} |> viewed_by?(%User{})
      false

  """
  def viewed_by?(viewable, %User{} = user) do
    view_count(viewable, user) > 0
  end

  def view_count(viewable) do
    viewable
    |> views()
    |> Repo.aggregate(:count, :id)
  end

  defp view_count(viewable, %User{} = user) do
    viewable
    |> views()
    |> where([f], f.user_id == ^user.id)
    |> Repo.aggregate(:count, :id)
  end

  defp views(viewable) do
    viewable
    |> Ecto.assoc(:views)
  end

  def notifications_for(%User{} = user) do
    Notification
    |> where([n], n.user_id == ^user.id)
    |> Repo.all()
  end

  @doc """
  Send a notification to a user:

      iex> %User{} |> notify("Nice shoes")
      {:ok, %Notification{}}

  """
  def notify(%User{} = user, %{subject: subject, body: body, url: url}) do
    %Notification{}
    |> Notification.changeset(%{body: body, subject: subject, url: url, user_id: user.id})
    |> Repo.insert()
  end

  @doc """
  Gets a notification by id.

  Maybe returns a notification.
  """
  def get_notification(id) do
    Notification
    |> Repo.get(id)
  end

  def decorate_post_oembeds(%Post{} = post) do
    oembeds =
      post.body
      |> OembedExtractor.get_embeds()

    %Post{post | oembeds: oembeds}
  end

  defp generate_api_token(), do: Ecto.UUID.generate()

  def admin?(%User{} = user) do
    user =
      user
      |> Repo.preload(:roles)

    user.roles
    |> Enum.any?(fn role ->
      role.name == "admin"
    end)
  end

  def create_role(name) do
    %Role{}
    |> Role.changeset(%{name: name})
    |> Repo.insert()
  end

  def add_role(%User{} = user, %Role{} = role) do
    %RoleMembership{}
    |> RoleMembership.changeset(%{user_id: user.id, role_id: role.id})
    |> Repo.insert()
  end

  ## Live events
  #
  # LiveViews subscribe to these topics to update in real time:
  #
  #   * "forums:categories"       - {:category_created | :category_updated | :category_deleted, category}
  #   * "forums:category:<id>"    - {:thread_created | :thread_updated | :thread_deleted | :thread_activity, thread}
  #   * "forums:threads"          - the same thread events, for every category
  #   * "forums:thread:<id>"      - {:post_created, post} and the thread events for that thread

  @pubsub FirestormWeb.PubSub

  @doc "Subscribes the caller to a forums topic (see the list above)."
  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)

  defp broadcast(topic, message), do: Phoenix.PubSub.broadcast(@pubsub, topic, message)

  defp broadcast_thread(event, %Thread{} = thread) do
    message = {event, thread}
    broadcast("forums:threads", message)
    broadcast("forums:category:#{thread.category_id}", message)
    broadcast("forums:thread:#{thread.id}", message)
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(result, _fun), do: result
end
