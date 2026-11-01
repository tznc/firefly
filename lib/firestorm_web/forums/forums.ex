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
    View,
    ThreadRead,
    Notification,
    OembedExtractor,
    Role,
    RoleMembership,
    SpamGuard,
    Subscriptions
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

  def update_preferences(%User{} = user, attrs) do
    user |> User.preferences_changeset(attrs) |> Repo.update()
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

  # How long a thread a user has never opened counts as "new".
  @new_thread_days 14

  @doc """
  Returns the list of categories.

  ## Examples

      iex> list_categories()
      [%Category{}, ...]

  """
  def list_categories do
    Category
    |> order_by(asc: :position, asc: :title)
    |> Repo.all()
  end

  @doc "Top-level categories, each with its subcategories (both in display order)."
  def list_category_tree do
    children = from(c in Category, order_by: [asc: c.position, asc: c.title])

    Category
    |> where([c], is_nil(c.parent_id))
    |> order_by(asc: :position, asc: :title)
    |> preload(children: ^children)
    |> Repo.all()
  end

  @doc "Top-level categories other than `category` (candidates for its parent)."
  def parent_category_options(%Category{id: id}) do
    Category
    |> where([c], is_nil(c.parent_id))
    |> then(fn q -> if id, do: where(q, [c], c.id != ^id), else: q end)
    |> order_by(asc: :position, asc: :title)
    |> Repo.all()
  end

  def get_category_with_family!(id) do
    children = from(c in Category, order_by: [asc: c.position, asc: c.title])
    Category |> preload([:parent, children: ^children]) |> Repo.get!(id)
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

  @doc "Gets a single category, or nil."
  def get_category(id), do: Repo.get(Category, id)

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
    |> order_by([t], desc_nulls_last: t.pinned_at)
    |> by_last_activity()
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
    subcategory_ids = from(c in Category, where: c.parent_id == ^category.id, select: c.id)

    Thread
    |> where([t], t.category_id == ^category.id or t.category_id in subquery(subcategory_ids))
    |> order_by([t], desc_nulls_last: t.pinned_at)
    |> by_last_activity()
    |> preload(:category)
    |> Repo.all()
    |> decorate_threads(user)
  end

  # Decorates threads with list data, in two queries for the whole list:
  #   - first_post (with its user)
  #   - posts_count, last_post_at
  #   - for a user: unread_count, first_unread_post_id, new? (never opened) and
  #     completely_read?
  defp decorate_threads([], _user), do: []

  defp decorate_threads(threads, user) do
    ids = Enum.map(threads, & &1.id)
    stats = thread_stats(ids, user)
    first_posts = first_posts(ids)

    Enum.map(threads, fn thread ->
      stat = Map.get(stats, thread.id, %{posts_count: 0, last_post_at: nil, read_post_id: nil})
      read? = not is_nil(stat[:read_post_id])

      {unread_count, first_unread} =
        cond do
          is_nil(user) -> {0, nil}
          read? -> {stat.unread_count, stat.first_unread_post_id}
          true -> {stat.posts_count, nil}
        end

      %{
        thread
        | first_post: Map.get(first_posts, thread.id),
          posts_count: stat.posts_count,
          last_post_at: stat.last_post_at,
          unread_count: unread_count,
          first_unread_post_id: first_unread,
          new?: not is_nil(user) and not read? and recent?(thread),
          # Anonymous viewers have no read state, so nothing counts as read.
          completely_read?: not is_nil(user) and read? and unread_count == 0
      }
    end)
  end

  # "New" only applies within the same window as the New list, so long-standing
  # threads a user never opened don't all show the badge.
  defp recent?(%Thread{inserted_at: inserted_at}),
    do: NaiveDateTime.compare(inserted_at, new_since()) == :gt

  defp new_since, do: NaiveDateTime.add(NaiveDateTime.utc_now(), -@new_thread_days, :day)

  defp thread_stats(ids, user) do
    user_id = if user, do: user.id, else: -1

    Post
    |> where([p], p.thread_id in ^ids)
    |> join(:left, [p], r in ThreadRead, on: r.thread_id == p.thread_id and r.user_id == ^user_id)
    |> group_by([p], p.thread_id)
    |> select([p, r], {
      p.thread_id,
      %{
        posts_count: count(p.id),
        last_post_at: max(p.inserted_at),
        read_post_id: max(r.last_read_post_id),
        unread_count: filter(count(p.id), p.id > r.last_read_post_id),
        first_unread_post_id: filter(min(p.id), p.id > r.last_read_post_id)
      }
    })
    |> Repo.all()
    |> Map.new()
  end

  defp first_posts(ids) do
    Post
    |> where([p], p.thread_id in ^ids)
    |> distinct([p], p.thread_id)
    |> order_by([p], asc: p.thread_id, asc: p.inserted_at, asc: p.id)
    |> preload(:user)
    |> Repo.all()
    |> Map.new(&{&1.thread_id, &1})
  end

  # The cross-category lists (Latest, New, Unread, Top) leave out archived
  # threads and the user's muted ones.
  defp listed(query, user), do: query |> where([t], is_nil(t.archived_at)) |> without_muted(user)

  defp without_muted(query, nil), do: query

  defp without_muted(query, %User{} = user) do
    where(query, [t], t.id not in subquery(Subscriptions.muted_thread_ids(user)))
  end

  # Threads ordered by their latest post (most recently active first).
  defp by_last_activity(query) do
    query
    |> join(
      :left_lateral,
      [t],
      lp in fragment(
        "SELECT max(inserted_at) AS at FROM forums_posts WHERE forums_posts.thread_id = ?",
        t.id
      ),
      on: true,
      as: :last_post
    )
    |> order_by([last_post: lp], desc_nulls_last: lp.at)
  end

  @doc "Every thread, most recently active first (the Latest list)."
  def latest_threads(user_or_nil) do
    Thread
    |> listed(user_or_nil)
    |> by_last_activity()
    |> preload(:category)
    |> Repo.all()
    |> decorate_threads(user_or_nil)
  end

  @doc """
  Threads started in the last #{@new_thread_days} days that the user has never
  opened, newest first.
  """
  def new_threads(%User{} = user) do
    since = new_since()

    query = from(t in Thread, as: :thread)

    query
    |> listed(user)
    |> where([t], t.inserted_at > ^since)
    |> where(
      [t],
      not exists(
        from(r in ThreadRead,
          where: r.thread_id == parent_as(:thread).id and r.user_id == ^user.id
        )
      )
    )
    |> order_by(desc: :inserted_at)
    |> preload(:category)
    |> Repo.all()
    |> decorate_threads(user)
  end

  @doc "Threads the user has read before that have posts since, most recently active first."
  def unread_threads(%User{} = user) do
    query = from(t in Thread, as: :thread)

    query
    |> listed(user)
    |> join(:inner, [t], r in ThreadRead,
      as: :read,
      on: r.thread_id == t.id and r.user_id == ^user.id
    )
    |> where(
      exists(
        from(p in Post,
          where:
            p.thread_id == parent_as(:thread).id and
              p.id > parent_as(:read).last_read_post_id
        )
      )
    )
    |> by_last_activity()
    |> preload(:category)
    |> Repo.all()
    |> decorate_threads(user)
  end

  @top_periods %{
    "day" => 1,
    "week" => 7,
    "month" => 30,
    "year" => 365,
    "all" => nil
  }

  @doc "The periods `top_threads/2` accepts."
  def top_periods, do: ~w(day week month year all)

  @doc """
  The most active threads: ranked by how many posts they got in the period
  (`"day"`, `"week"`, `"month"`, `"year"` or `"all"`).
  """
  def top_threads(period, user_or_nil) when is_map_key(@top_periods, period) do
    posts =
      case @top_periods[period] do
        nil ->
          Post

        days ->
          since = NaiveDateTime.add(NaiveDateTime.utc_now(), -days, :day)
          where(Post, [p], p.inserted_at > ^since)
      end

    ranked =
      posts
      |> group_by([p], p.thread_id)
      |> select([p], %{thread_id: p.thread_id, posts: count(p.id), last_at: max(p.inserted_at)})

    Thread
    |> listed(user_or_nil)
    |> join(:inner, [t], r in subquery(ranked), on: r.thread_id == t.id)
    |> order_by([t, r], desc: r.posts, desc: r.last_at)
    |> limit(50)
    |> preload(:category)
    |> Repo.all()
    |> decorate_threads(user_or_nil)
  end

  # Reading a thread reads its notifications.
  defp read_thread_notifications(user, thread) do
    Notification
    |> where([n], n.user_id == ^user.id and n.thread_id == ^thread.id and is_nil(n.read_at))
    |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])
    |> case do
      {0, _} -> :ok
      _ -> notifications_changed(user.id)
    end
  end

  @doc "The ids of users whose read position in `thread` is at or past `post`."
  def users_who_read(%Thread{id: thread_id}, %Post{id: post_id}) do
    ThreadRead
    |> where([r], r.thread_id == ^thread_id and r.last_read_post_id >= ^post_id)
    |> select([r], r.user_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc "The user's read position in a thread, or nil if they've never opened it."
  def thread_read(%User{id: user_id}, %Thread{id: thread_id}) do
    Repo.get_by(ThreadRead, user_id: user_id, thread_id: thread_id)
  end

  def thread_read(nil, _thread), do: nil

  @doc """
  Marks the thread read up to its newest post. The position only moves forward.
  """
  def mark_thread_read(%User{} = user, %Thread{} = thread) do
    last_post_id =
      Post |> where([p], p.thread_id == ^thread.id) |> select([p], max(p.id)) |> Repo.one()

    if last_post_id do
      result = advance_read(user.id, thread.id, last_post_id)
      read_thread_notifications(user, thread)
      result
    else
      {:ok, nil}
    end
  end

  # Moves a read position forward to `post_id` (never backwards).
  defp advance_read(user_id, thread_id, post_id) do
    now = NaiveDateTime.utc_now()

    on_conflict =
      from(r in ThreadRead,
        update: [
          set: [
            last_read_post_id:
              fragment("GREATEST(?, EXCLUDED.last_read_post_id)", r.last_read_post_id),
            updated_at: ^now
          ]
        ]
      )

    Repo.insert(
      %ThreadRead{user_id: user_id, thread_id: thread_id, last_read_post_id: post_id},
      on_conflict: on_conflict,
      conflict_target: [:user_id, :thread_id]
    )
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
      |> Thread.new_changeset(user)
      |> Repo.insert()

    case thread_result do
      {:ok, thread} ->
        {:ok, _} = mark_thread_read(user, thread)

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
        {:ok, _} = Subscriptions.ensure_thread_level(user, thread, "watching")
        :ok = Notifications.thread_created(thread)
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

  @doc "Pins or unpins a thread (pinned threads list first in their category)."
  def pin_thread(%Thread{} = thread, pinned?), do: moderate(thread, pinned_at: stamp(pinned?))

  @doc "Closes or reopens a thread to new replies."
  def close_thread(%Thread{} = thread, closed?), do: moderate(thread, closed_at: stamp(closed?))

  @doc "Archives (closes and hides from Latest/New/Unread/Top) or unarchives a thread."
  def archive_thread(%Thread{} = thread, archived?),
    do: moderate(thread, archived_at: stamp(archived?))

  @doc "Moves a thread to another category."
  def move_thread(%Thread{category_id: old_category_id} = thread, %Category{id: category_id}) do
    with {:ok, moved} <- moderate(thread, category_id: category_id) do
      if old_category_id != category_id,
        do: broadcast("forums:category:#{old_category_id}", {:thread_deleted, moved})

      {:ok, moved}
    end
  end

  defp stamp(true), do: DateTime.utc_now(:second)
  defp stamp(false), do: nil

  defp moderate(thread, changes) do
    thread
    |> Thread.moderation_changeset(Map.new(changes))
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
    if thread_closed?(thread.id),
      do: {:error, :closed},
      else: insert_post(thread, user, attrs)
  end

  @doc "Whether the thread is closed to new replies (closed or archived)."
  def thread_closed?(thread_id) do
    Thread
    |> where([t], t.id == ^thread_id)
    |> where([t], not is_nil(t.closed_at) or not is_nil(t.archived_at))
    |> Repo.exists?()
  end

  defp insert_post(thread, user, attrs) do
    attrs =
      attrs
      |> Map.put(:thread_id, thread.id)
      |> Map.put(:user_id, user.id)

    changeset = %Post{} |> Post.changeset(attrs) |> SpamGuard.validate_post(user)

    with {:ok, post} <- Repo.insert(changeset) do
      {:ok, _} = Subscriptions.ensure_thread_level(user, thread, "tracking")
      # Authors have read what they wrote, whichever way they posted it.
      {:ok, _} = advance_read(user.id, thread.id, post.id)
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

  @doc "Have a user watch a thread (notification level `watching`)."
  def watch(%User{} = user, %Thread{} = thread),
    do: Subscriptions.set_thread_level(user, thread, "watching")

  @doc "Stop watching a thread (notification level `normal`)."
  def unwatch(%User{} = user, %Thread{} = thread) do
    {:ok, _} = Subscriptions.set_thread_level(user, thread, "normal")
    :ok
  end

  @doc "Whether the user watches the thread (by their own choice on the thread)."
  def watched_by?(%Thread{} = thread, %User{} = user),
    do: Subscriptions.thread_level(user, thread) == "watching"

  def watched_threads(%User{} = user) do
    user
    |> Subscriptions.watched_thread_ids()
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
    |> where([t], t.id in ^thread_ids)
    |> by_last_activity()
    |> preload(:category)
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

  @doc "The user's notifications, newest first."
  def notifications_for(%User{} = user) do
    Notification
    |> where([n], n.user_id == ^user.id)
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(100)
    |> Repo.all()
  end

  def unread_notification_count(%User{} = user) do
    Notification
    |> where([n], n.user_id == ^user.id and is_nil(n.read_at))
    |> Repo.aggregate(:count)
  end

  @doc """
  Sends a notification to a user, and tells their open pages so the badge
  updates live.
  """
  def notify(%User{} = user, attrs) do
    result =
      %Notification{}
      |> Notification.changeset(Map.put(attrs, :user_id, user.id))
      |> Repo.insert()

    with {:ok, _} <- result, do: notifications_changed(user.id)
    result
  end

  def mark_notification_read(%Notification{read_at: nil} = notification) do
    {:ok, notification} =
      notification |> change(read_at: DateTime.utc_now(:second)) |> Repo.update()

    notifications_changed(notification.user_id)
    {:ok, notification}
  end

  def mark_notification_read(%Notification{} = notification), do: {:ok, notification}

  def mark_all_notifications_read(%User{} = user) do
    Notification
    |> where([n], n.user_id == ^user.id and is_nil(n.read_at))
    |> Repo.update_all(set: [read_at: DateTime.utc_now(:second)])
    |> case do
      {0, _} -> :ok
      _ -> notifications_changed(user.id)
    end
  end

  @doc "Marks the notification as emailed."
  def notification_emailed(%Notification{} = notification) do
    notification |> change(emailed_at: DateTime.utc_now(:second)) |> Repo.update()
  end

  @doc """
  Whether the user already has an unread, emailed notification for the
  thread. Used to send one email per thread until the user comes back.
  """
  def unread_emailed_notification?(%User{} = user, thread_id, except_id) do
    Notification
    |> where([n], n.user_id == ^user.id and n.thread_id == ^thread_id and n.id != ^except_id)
    |> where([n], is_nil(n.read_at) and not is_nil(n.emailed_at))
    |> Repo.exists?()
  end

  def notifications_topic(user_id), do: "user:#{user_id}:notifications"

  defp notifications_changed(user_id) do
    Phoenix.PubSub.broadcast(
      FirestormWeb.PubSub,
      notifications_topic(user_id),
      :notifications_changed
    )
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

    # A parent category's page lists its subcategories' threads too.
    parent_id =
      Repo.one(from(c in Category, where: c.id == ^thread.category_id, select: c.parent_id))

    if parent_id, do: broadcast("forums:category:#{parent_id}", message)
  end

  defp tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  defp tap_ok(result, _fun), do: result
end
