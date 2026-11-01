defmodule FirestormWeb.Forums do
  @moduledoc """
  The boundary for the Forums system.
  """

  defdelegate authorize(action, user, params), to: FirestormWeb.Forums.Policy
  import Ecto.{Query, Changeset}, warn: false
  alias FirestormWeb.{Repo, Notifications, SiteSettings, StaffLog}
  alias FirestormWeb.Web.Endpoint
  alias FirestormWeb.Store.ReplenishResponse

  alias FirestormWeb.Forums.{
    User,
    Category,
    Thread,
    Diff,
    Post,
    PostLike,
    PostRevision,
    View,
    ThreadRead,
    Notification,
    OembedExtractor,
    Policy,
    Role,
    RoleMembership,
    SpamGuard,
    Subscriptions,
    Tag
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

  @doc "The user directory: newest first, leaving out users who hid themselves from it."
  def paginate_users(page) do
    User
    |> where([u], not u.hide_from_directory)
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
  The users with the given usernames (any case), as a map from each given
  name to its user. Deleted accounts can't be mentioned or messaged.
  """
  def users_by_username([]), do: %{}

  def users_by_username(names) do
    by_lower =
      User
      |> where([u], fragment("lower(?)", u.username) in ^Enum.map(names, &String.downcase/1))
      |> where([u], is_nil(u.deleted_at))
      |> order_by(asc: :id)
      |> Repo.all()
      |> Enum.group_by(&String.downcase(&1.username))

    # Usernames are only unique case-sensitively, so `@alice` could fit both
    # "Alice" and "alice": the exact match wins, else the oldest account.
    for name <- names, users = by_lower[String.downcase(name)], into: %{} do
      {name, Enum.find(users, hd(users), &(&1.username == name))}
    end
  end

  @doc "Up to `limit` users whose username starts with `prefix` (any case), shortest first."
  def search_usernames(prefix, limit \\ 6) do
    pattern = String.replace(String.downcase(prefix), ~r/[\\%_]/, "\\\\\\0") <> "%"

    # `lower(username) LIKE` rather than ILIKE, so it can use the index.
    User
    |> where([u], like(fragment("lower(?)", u.username), ^pattern) and is_nil(u.deleted_at))
    |> order_by([u], asc: fragment("length(?)", u.username), asc: u.username)
    |> limit(^limit)
    |> Repo.all()
  end

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
    # Whether that's needed to post is the `require_email_confirmation`
    # setting's job (see `FirestormWeb.Posting`): `confirmed_at` only ever
    # means the address was proven.
    if registration_open?() do
      %User{api_token: generate_api_token()}
      |> User.registration_changeset(attrs)
      |> Repo.insert()
    else
      {:error, :registration_closed}
    end
  end

  @doc "Whether new accounts may be created (the `allow_registrations` site setting)."
  def registration_open?, do: SiteSettings.get("allow_registrations")

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
  Returns the list of categories `viewer` may read (nil: a visitor; see
  `FirestormWeb.Forums.Policy`).

  ## Examples

      iex> list_categories(user)
      [%Category{}, ...]

  """
  def list_categories(viewer \\ nil) do
    Category
    |> Policy.readable_categories(viewer)
    |> order_by(asc: :position, asc: :title)
    |> Repo.all()
  end

  @doc """
  Top-level categories `viewer` may read, each with its readable
  subcategories (both in display order), marked `restricted` (see
  `mark_restricted/1`).
  """
  def list_category_tree(viewer \\ nil) do
    children =
      Category
      |> order_by(asc: :position, asc: :title)
      |> Policy.readable_categories(viewer)

    Category
    |> where([c], is_nil(c.parent_id))
    |> Policy.readable_categories(viewer)
    |> order_by(asc: :position, asc: :title)
    |> preload(children: ^children)
    |> Repo.all()
    |> mark_restricted()
  end

  @doc """
  Sets `restricted` on categories (and their loaded parents and children)
  that are restricted to roles, directly or through their parent: the ones
  that get a lock icon.
  """
  def mark_restricted(categories) do
    restricted = MapSet.new(Repo.all(Policy.hidden_category_ids(nil)))
    mark = &mark_restricted(&1, restricted)
    Enum.map(categories, mark)
  end

  defp mark_restricted(%Category{} = category, restricted) do
    category = %{category | restricted: MapSet.member?(restricted, category.id)}

    category
    |> Map.update!(
      :parent,
      &if(match?(%Category{}, &1), do: mark_restricted(&1, restricted), else: &1)
    )
    |> Map.update!(:children, fn
      children when is_list(children) -> Enum.map(children, &mark_restricted(&1, restricted))
      not_loaded -> not_loaded
    end)
  end

  defp mark_restricted(other, _restricted), do: other

  @doc "Top-level categories other than `category` (candidates for its parent)."
  def parent_category_options(%Category{id: id}) do
    Category
    |> where([c], is_nil(c.parent_id))
    |> then(fn q -> if id, do: where(q, [c], c.id != ^id), else: q end)
    |> order_by(asc: :position, asc: :title)
    |> Repo.all()
  end

  @doc """
  A category `viewer` may read, with its parent and readable children, all
  marked `restricted` and its own `roles` loaded. Raises
  `Ecto.NoResultsError` (a 404) otherwise.
  """
  def get_category_with_family!(id, viewer) do
    children =
      Category
      |> order_by(asc: :position, asc: :title)
      |> Policy.readable_categories(viewer)

    [category] =
      Category
      |> Policy.readable_categories(viewer)
      |> preload([:parent, :roles, children: ^children])
      |> Repo.get!(id)
      |> List.wrap()
      |> mark_restricted()

    category
  end

  @doc """
  Gets a category `viewer` may read (see the `:view_category` policy).
  Raises `Ecto.NoResultsError` (a 404, as if it didn't exist) otherwise.
  """
  def get_visible_category!(id, viewer) do
    Category |> Policy.readable_categories(viewer) |> Repo.get!(id)
  end

  @doc """
  Gets a thread in `category` that `viewer` may read (see the `:view_thread`
  policy). Raises `Ecto.NoResultsError` otherwise.
  """
  def get_visible_thread!(%Category{id: category_id}, id, viewer) do
    threads_query()
    |> where([t], t.category_id == ^category_id)
    |> Policy.readable_threads(viewer)
    |> Repo.get!(id)
  end

  # Threads, bound as `:thread` (see `Policy.readable_threads/2`).
  defp threads_query, do: from(t in Thread, as: :thread)

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
          "SELECT thread_id, inserted_at FROM forums_posts WHERE forums_posts.thread_id = ? AND forums_posts.deleted_at IS NULL ORDER BY forums_posts.inserted_at DESC LIMIT 1",
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

  @doc """
  The categories `viewer` may read with the given (downcased) slugs, as a
  map from slug to category.
  """
  def categories_by_slug(slugs, viewer \\ nil)
  def categories_by_slug([], _viewer), do: %{}

  def categories_by_slug(slugs, viewer) do
    Category
    |> where([c], c.slug in ^slugs)
    |> Policy.readable_categories(viewer)
    |> Repo.all()
    |> Map.new(&{&1.slug, &1})
  end

  @doc "Gets a single category, or nil."
  def get_category(id), do: Repo.get(Category, id)

  @doc """
  Creates a category. With an `actor` (the admin doing it), the change goes
  to the staff log; seeds and scripts pass none. The same goes for
  `update_category/3` and `delete_category/2`. A `role_ids` attribute (a
  list of role ids) restricts the category to those roles; empty: open to
  everyone.

  ## Examples

      iex> create_category(%{title: "Elixir"})
      {:ok, %Category{}}

      iex> create_category(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_category(attrs \\ %{}, actor \\ nil) do
    result =
      logged(
        fn -> %Category{} |> Category.changeset(attrs) |> put_roles(attrs) |> Repo.insert() end,
        &StaffLog.record(
          actor,
          "category.create",
          &1,
          Map.merge(%{title: &1.title}, roles_details([], &1.roles))
        )
      )

    tap_ok(result, &broadcast("forums:categories", {:category_created, &1}))
  end

  @doc """
  Updates a category.

  ## Examples

      iex> update_category(category, %{field: new_value})
      {:ok, %Category{}}

      iex> update_category(category, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_category(%Category{} = category, attrs, actor \\ nil) do
    category = Repo.preload(category, :roles)
    changeset = category |> Category.changeset(attrs) |> put_roles(attrs)
    details = StaffLog.changes(changeset)

    result =
      logged(fn -> Repo.update(changeset) end, fn updated ->
        details = Map.merge(details, roles_details(category.roles, updated.roles))

        if details != %{},
          do:
            StaffLog.record(
              actor,
              "category.update",
              updated,
              Map.put_new(details, :title, updated.title)
            )
      end)

    tap_ok(result, &broadcast("forums:categories", {:category_updated, &1}))
  end

  # Restricts the category to the roles in `attrs`' `role_ids` (blank
  # entries ignored, so a form can clear them); none given leaves them.
  defp put_roles(changeset, attrs) do
    case attrs["role_ids"] || attrs[:role_ids] do
      nil ->
        changeset

      ids ->
        ids = for id <- List.wrap(ids), {id, ""} <- [Integer.parse(to_string(id))], do: id
        put_assoc(changeset, :roles, Repo.all(from(r in Role, where: r.id in ^ids)))
    end
  end

  defp roles_details(before, after_roles) do
    names = fn
      roles when is_list(roles) -> roles |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(", ")
      _not_loaded -> ""
    end

    case {names.(before), names.(after_roles)} do
      {same, same} -> %{}
      {"", now} -> %{restricted_to: now}
      {was, now} -> %{restricted_to: %{before: was, after: now}}
    end
  end

  @doc """
  Deletes a Category.

  ## Examples

      iex> delete_category(category)
      {:ok, %Category{}}

      iex> delete_category(category)
      {:error, %Ecto.Changeset{}}

  """
  def delete_category(%Category{} = category, actor \\ nil) do
    result =
      logged(
        fn -> Repo.delete(category) end,
        &StaffLog.record(actor, "category.delete", &1, %{title: &1.title})
      )

    tap_ok(result, &broadcast("forums:categories", {:category_deleted, &1}))
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
  Returns the threads in a given category and its subcategories (those the
  user may read) ordered by those with the most recent posts. If provided a
  user, will determine whether each thread has been completely read or not.

  ## Examples

      iex> recent_threads(category)
      [%Thread{}, ...]

  """
  def recent_threads(category, user \\ nil) do
    subcategory_ids = from(c in Category, where: c.parent_id == ^category.id, select: c.id)

    threads_query()
    |> where([t], t.category_id == ^category.id or t.category_id in subquery(subcategory_ids))
    |> Policy.readable_threads(user)
    |> order_by([t], desc_nulls_last: t.pinned_at)
    |> by_last_activity()
    |> preload(:category)
    |> Repo.all()
    |> decorate_threads(user)
  end

  # Decorates threads with list data, in two queries for the whole list
  # (deleted posts don't count):
  #   - tags
  #   - first_post (with its user)
  #   - posts_count, last_post_at
  #   - for a user: unread_count, first_unread_post_id, new? (never opened) and
  #     completely_read?
  defp decorate_threads([], _user), do: []

  defp decorate_threads(threads, user) do
    threads = threads |> Repo.preload(:tags) |> mark_thread_categories()
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

  defp mark_thread_categories(threads) do
    if Enum.any?(threads, &Ecto.assoc_loaded?(&1.category)) do
      restricted = MapSet.new(Repo.all(Policy.hidden_category_ids(nil)))

      Enum.map(threads, &mark_thread_category(&1, restricted))
    else
      threads
    end
  end

  defp mark_thread_category(%Thread{category: %Category{} = category} = thread, restricted),
    do: %{thread | category: mark_restricted(category, restricted)}

  defp mark_thread_category(thread, _restricted), do: thread

  # "New" only applies within the same window as the New list, so long-standing
  # threads a user never opened don't all show the badge.
  defp recent?(%Thread{inserted_at: inserted_at}),
    do: NaiveDateTime.compare(inserted_at, new_since()) == :gt

  defp new_since, do: NaiveDateTime.add(NaiveDateTime.utc_now(), -@new_thread_days, :day)

  defp thread_stats(ids, user) do
    user_id = if user, do: user.id, else: -1

    Post
    |> Post.visible()
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
  # threads and the user's muted ones, and only show threads the user may
  # read (the query must bind the thread as `:thread`). A tag's own page
  # keeps the muted ones (`keep_muted: true`), as a category's page does:
  # muting the tag hides its threads elsewhere, it doesn't empty the tag.
  defp listed(query, user, opts \\ []) do
    query
    |> where([t], is_nil(t.archived_at))
    |> without_muted(if opts[:keep_muted], do: nil, else: user)
    |> Policy.readable_threads(user)
  end

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
        "SELECT max(inserted_at) AS at FROM forums_posts WHERE forums_posts.thread_id = ? AND forums_posts.deleted_at IS NULL",
        t.id
      ),
      on: true,
      as: :last_post
    )
    |> order_by([last_post: lp], desc_nulls_last: lp.at)
  end

  @doc "Every thread, most recently active first (the Latest list)."
  def latest_threads(user_or_nil) do
    threads_query()
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

    threads_query()
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
    threads_query()
    |> listed(user)
    |> join(:inner, [t], r in ThreadRead,
      as: :read,
      on: r.thread_id == t.id and r.user_id == ^user.id
    )
    |> where(
      exists(
        from(p in Post,
          where:
            p.thread_id == parent_as(:thread).id and is_nil(p.deleted_at) and
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
  (`"day"`, `"week"`, `"month"`, `"year"` or `"all"`). Likes given in the
  period break ties: replies stay the main signal of activity (a like is a
  cheap, one-click reaction), but among equally busy threads the one people
  appreciated more ranks first. Then the most recently active.
  """
  def top_threads(period, user_or_nil) when is_map_key(@top_periods, period) do
    since =
      case @top_periods[period] do
        nil -> ~N[0000-01-01 00:00:00]
        days -> NaiveDateTime.add(NaiveDateTime.utc_now(), -days, :day)
      end

    ranked =
      Post
      |> Post.visible()
      |> where([p], p.inserted_at > ^since)
      |> group_by([p], p.thread_id)
      |> select([p], %{thread_id: p.thread_id, posts: count(p.id), last_at: max(p.inserted_at)})

    liked =
      PostLike
      |> join(:inner, [l], p in assoc(l, :post))
      |> where([l, p], is_nil(p.deleted_at) and l.inserted_at > ^since)
      |> group_by([l, p], p.thread_id)
      |> select([l, p], %{thread_id: p.thread_id, likes: count(l.id)})

    threads_query()
    |> listed(user_or_nil)
    |> join(:inner, [t], r in subquery(ranked), on: r.thread_id == t.id)
    |> join(:left, [t], l in subquery(liked), on: l.thread_id == t.id)
    |> order_by([t, r, l], desc: r.posts, desc: coalesce(l.likes, 0), desc: r.last_at)
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

  @doc "Gets a post in `thread`. Raises `Ecto.NoResultsError` if it isn't there."
  def get_post!(%Thread{id: thread_id}, id) do
    Post
    |> where([p], p.thread_id == ^thread_id)
    |> Repo.get!(id)
  end

  @doc "Gets a post in `thread`, or nil."
  def get_post(%Thread{id: thread_id}, id) do
    Post
    |> where([p], p.thread_id == ^thread_id)
    |> Repo.get(id)
  end

  @doc """
  Creates a thread.

  ## Examples

      iex> create_thread(category, user, %{title: "OTP is cool", body: "don't you think?", tags: "otp, beam"})
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
      |> put_tags(attrs[:tags], user)
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
        {:ok, _} = Subscriptions.ensure_thread_level(user, thread, user.new_thread_level)
        :ok = Notifications.thread_created(thread)
        {:ok, thread}

      e ->
        e
    end
  end

  @doc """
  Updates a thread. A `tags` attribute (comma- or space-separated names)
  replaces its tags; tags that don't exist yet are created if `editor` may
  (see `may_create_tags?/1`). An admin's edit of someone else's thread goes
  to the staff log.

  ## Examples

      iex> update_thread(thread, %{field: new_value})
      {:ok, %Thread{}}

      iex> update_thread(thread, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_thread(%Thread{} = thread, attrs, editor \\ nil) do
    thread = Repo.preload(thread, :tags)

    changeset =
      thread
      |> Thread.changeset(attrs)
      |> put_tags(attrs[:tags] || attrs["tags"], editor)

    staff? = staff_on_others?(editor, thread_author_id(thread))

    result =
      logged(fn -> Repo.update(changeset) end, fn updated ->
        if staff?, do: log_thread_edit(editor, thread, updated)
      end)

    tap_ok(result, &broadcast_thread(:thread_updated, &1))
  end

  defp log_thread_edit(editor, before, updated) do
    tag_names = &Enum.map_join(&1.tags, ", ", fn tag -> tag.name end)

    details =
      [title: {before.title, updated.title}, tags: {tag_names.(before), tag_names.(updated)}]
      |> Enum.reject(fn {_field, {old, new}} -> old == new end)
      |> Map.new(fn {field, {old, new}} -> {field, %{before: old, after: new}} end)

    if details != %{},
      do:
        StaffLog.record(
          editor,
          "thread.edit",
          updated,
          Map.put_new(details, :title, updated.title)
        )
  end

  # Whether `actor` is acting on someone else's content: a staff action, for
  # the log. (The policies only let admins do that.)
  defp staff_on_others?(nil, _author_id), do: false
  defp staff_on_others?(%User{id: id}, author_id), do: id != author_id

  # Runs `action` (returning `{:ok, record}` or an error) and, if it
  # succeeds, `log.(record)` in the same transaction: the staff log records
  # an action if and only if it happened.
  defp logged(action, log) do
    Repo.transact(fn ->
      with {:ok, record} <- action.() do
        log.(record)
        {:ok, record}
      end
    end)
  end

  @doc """
  Whether `user` may create tags: members may unless the `tags_admin_only`
  site setting (seeded from `FIREFLY_TAGS_ADMIN_ONLY`) is on; admins always.
  """
  def may_create_tags?(%User{} = user),
    do: not SiteSettings.get("tags_admin_only") or admin?(user)

  def may_create_tags?(nil), do: false

  # Sets the thread's tags from user input (see `Tag.parse/1`); nil leaves
  # them as they are. Unknown tags are created, if `user` may.
  defp put_tags(changeset, nil, _user), do: changeset

  defp put_tags(changeset, input, user) do
    names = Tag.parse(input)
    existing = Tag |> where([t], t.name in ^names) |> Repo.all() |> Map.new(&{&1.name, &1})
    new = Enum.reject(names, &Map.has_key?(existing, &1))
    invalid = Enum.reject(new, &Tag.valid_name?/1)

    cond do
      length(names) > Tag.max_per_thread() ->
        add_error(changeset, :tags, "can have at most %{count} tags", count: Tag.max_per_thread())

      invalid != [] ->
        add_error(
          changeset,
          :tags,
          "#{Enum.join(invalid, ", ")}: use lowercase letters, digits and dashes (30 at most)"
        )

      new != [] and not may_create_tags?(user) ->
        add_error(changeset, :tags, "#{Enum.join(new, ", ")}: no such tag")

      new == [] or not changeset.valid? ->
        tags = Enum.map(names, &(existing[&1] || Tag.changeset(%Tag{}, %{name: &1})))
        put_assoc(changeset, :tags, tags)

      true ->
        put_assoc(changeset, :tags, ensure_tags(names))
    end
  end

  @doc """
  The tags named `names` (valid names), in order, creating the missing ones.
  Tags someone else creates at the same moment are taken as they are, where a
  nested insert would fail the whole save on the unique name.
  """
  def ensure_tags(names) do
    now = NaiveDateTime.utc_now()
    rows = Enum.map(names, &%{name: &1, inserted_at: now, updated_at: now})
    Repo.insert_all(Tag, rows, on_conflict: :nothing, conflict_target: :name)
    by_name = Tag |> where([t], t.name in ^names) |> Repo.all() |> Map.new(&{&1.name, &1})
    Enum.map(names, &Map.fetch!(by_name, &1))
  end

  @doc """
  Every tag with at least one listed thread `viewer` may read, with
  `threads_count`, most used first.
  """
  def list_tags(viewer \\ nil) do
    Tag
    |> join(:inner, [t], tt in "forums_threads_tags", on: tt.tag_id == t.id)
    |> join(:inner, [t, tt], th in Thread,
      as: :thread,
      on: th.id == tt.thread_id and is_nil(th.archived_at)
    )
    |> Policy.readable_threads(viewer)
    |> group_by([t], t.id)
    |> order_by([t, tt], desc: count(tt.thread_id), asc: t.name)
    |> select([t, tt], %{t | threads_count: count(tt.thread_id)})
    |> Repo.all()
  end

  @doc "Gets a tag by name. Raises `Ecto.NoResultsError` if there's none."
  def get_tag!(name), do: Repo.get_by!(Tag, name: String.downcase(name))

  @doc "A tag's threads (leaving out archived ones), most recently active first."
  def tag_threads(%Tag{id: tag_id}, user_or_nil) do
    threads_query()
    |> join(:inner, [t], tt in "forums_threads_tags", on: tt.thread_id == t.id)
    |> where([t, tt], tt.tag_id == ^tag_id)
    |> listed(user_or_nil, keep_muted: true)
    |> by_last_activity()
    |> preload(:category)
    |> Repo.all()
    |> decorate_threads(user_or_nil)
  end

  # Thread moderation is admin-only (the `:moderate_thread` policy); each
  # action is recorded in the staff log as `actor`'s.

  @doc "Pins or unpins a thread (pinned threads list first in their category)."
  def pin_thread(%Thread{} = thread, pinned?, actor),
    do:
      moderate(thread, actor, if(pinned?, do: "thread.pin", else: "thread.unpin"),
        pinned_at: stamp(pinned?)
      )

  @doc "Closes or reopens a thread to new replies."
  def close_thread(%Thread{} = thread, closed?, actor),
    do:
      moderate(thread, actor, if(closed?, do: "thread.close", else: "thread.open"),
        closed_at: stamp(closed?)
      )

  @doc "Archives (closes and hides from Latest/New/Unread/Top) or unarchives a thread."
  def archive_thread(%Thread{} = thread, archived?, actor),
    do:
      moderate(thread, actor, if(archived?, do: "thread.archive", else: "thread.unarchive"),
        archived_at: stamp(archived?)
      )

  @doc """
  Moves a thread to another category (a no-op, not logged, if it's already
  there). The log notes when the move put the thread in a restricted
  category (one only some groups can read).
  """
  def move_thread(%Thread{category_id: id} = thread, %Category{id: id}, _actor),
    do: {:ok, thread}

  def move_thread(%Thread{category_id: old_category_id} = thread, %Category{} = category, actor) do
    details = %{
      from_category: Repo.get(Category, old_category_id).title,
      to_category: category.title
    }

    details =
      if Repo.exists?(where(Policy.hidden_category_ids(nil), [c], c.id == ^category.id)),
        do: Map.put(details, :restricted, true),
        else: details

    with {:ok, moved} <-
           moderate(thread, actor, "thread.move", [category_id: category.id], details) do
      broadcast("forums:category:#{old_category_id}", {:thread_deleted, moved})
      {:ok, moved}
    end
  end

  defp stamp(true), do: DateTime.utc_now(:second)
  defp stamp(false), do: nil

  defp moderate(thread, actor, action, changes, details \\ %{}) do
    result =
      logged(
        fn -> thread |> Thread.moderation_changeset(Map.new(changes)) |> Repo.update() end,
        &StaffLog.record(actor, action, &1, Map.put(details, :title, &1.title))
      )

    tap_ok(result, &broadcast_thread(:thread_updated, &1))
  end

  @doc """
  Deletes a thread as `actor` (its author or an admin). An admin deleting
  someone else's thread goes to the staff log.

  ## Examples

      iex> delete_thread(thread, user)
      {:ok, %Thread{}}

  """
  def delete_thread(%Thread{} = thread, %User{} = actor) do
    # Asked first: the thread's posts go with it.
    staff? = staff_on_others?(actor, thread_author_id(thread))

    result =
      logged(fn -> Repo.delete(thread) end, fn deleted ->
        if staff?, do: log_thread_delete(actor, deleted)
      end)

    tap_ok(result, &broadcast_thread(:thread_deleted, &1))
  end

  defp log_thread_delete(actor, thread) do
    category = Repo.get(Category, thread.category_id)

    StaffLog.record(actor, "thread.delete", thread, %{
      title: thread.title,
      category: category.title
    })
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
    if registration_open?(),
      do: insert_github_user(uid, nickname, name, email),
      else: {:error, "New registrations are closed."}
  end

  defp insert_github_user(uid, nickname, name, email) do
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

  # A GitHub login named like a deleted account's placeholder gets a prefix
  # (see `User.reserved_username?/1`).
  defp available_username(nickname, attempt \\ 0) do
    candidate = if attempt == 0, do: nickname, else: "#{nickname}-#{attempt}"

    cond do
      User.reserved_username?(nickname) -> available_username("gh-" <> nickname)
      get_user_by_username(candidate) -> available_username(nickname, attempt + 1)
      true -> candidate
    end
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
      {:ok, _} = Subscriptions.ensure_thread_level(user, thread, user.reply_level)
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

  @doc """
  Edits a post's body as `editor` (its author or an admin; see the
  `:edit_post` policy). The replaced body is kept as a `PostRevision`, so the
  post's history can be shown. Users the edit newly mentions are notified. New-account link limits apply to the edit as
  they do to new posts. Saving an unchanged body is a no-op.

  `post` is the version the editor started from: if someone else edited it
  since, this returns `{:error, :edited_elsewhere}` instead of overwriting
  their edit. Deleted posts give `{:error, :deleted}`.
  """
  def update_post(%Post{} = post, %User{} = editor, attrs) do
    result =
      Repo.transact(fn ->
        # Edit the row as it is now, not the caller's copy, so the revision
        # holds the body this edit actually replaces.
        current = Post |> lock("FOR UPDATE") |> Repo.get!(post.id)

        cond do
          # Deleted posts can't be edited, even from a form opened before.
          Post.deleted?(current) -> {:error, :deleted}
          current.edited_at != post.edited_at -> {:error, :edited_elsewhere}
          true -> edit_post(current, editor, attrs)
        end
      end)

    tap_ok(result, &broadcast_post_updated(&1, editor))
  end

  defp edit_post(current, editor, attrs) do
    changeset = current |> Post.edit_changeset(attrs) |> SpamGuard.validate_post(editor)

    if changeset.valid? and not Map.has_key?(changeset.changes, :body) do
      {:ok, current}
    else
      Repo.insert!(%PostRevision{post_id: current.id, user_id: editor.id, body: current.body})
      changeset = put_change(changeset, :edited_at, NaiveDateTime.utc_now())
      logged(fn -> Repo.update(changeset) end, &log_post_edit(editor, current, &1))
    end
  end

  defp log_post_edit(editor, post, updated) do
    if staff_on_others?(editor, post.user_id) do
      details = post_details(post, %{body: %{before: post.body, after: updated.body}})
      StaffLog.record(editor, "post.edit", updated, details)
    end
  end

  defp broadcast_post_updated(post, editor) do
    post = Repo.preload(post, [:thread, :user])

    # Mentions notify as the author's words: an admin's moderating edit
    # doesn't ping anyone in their name.
    if editor.id == post.user_id, do: :ok = Notifications.post_edited(post)

    payload = %ReplenishResponse{
      categories: [],
      threads: [post.thread],
      users: [post.user],
      posts: [post]
    }

    :ok = Endpoint.broadcast!("threads:#{post.thread_id}", "update", payload)
    broadcast("forums:thread:#{post.thread_id}", {:post_updated, post})
  end

  @doc """
  A post's edits, newest first: who edited it, when, and the word diff from
  the body before the edit to the body after it.
  """
  def post_edits(%Post{} = post) do
    revisions =
      PostRevision
      |> where([r], r.post_id == ^post.id)
      |> order_by([r], asc: r.inserted_at, asc: r.id)
      |> preload(:user)
      |> Repo.all()

    # Each revision holds the body its edit replaced; the next revision (or
    # the current body) is what the edit produced.
    afters = Enum.map(Enum.drop(revisions, 1), & &1.body) ++ [post.body]

    revisions
    |> Enum.zip_with(afters, fn revision, after_body ->
      %{
        editor: revision.user,
        at: revision.inserted_at,
        diff: Diff.words(revision.body, after_body)
      }
    end)
    |> Enum.reverse()
  end

  @doc """
  Soft-deletes a reply as `user` (its author or an admin; see the
  `:delete_post` policy). The row stays so admins can restore it; until then
  it's left out of counts, lists and notifications. A thread's first post
  can't be deleted on its own: delete the thread instead.
  """
  def delete_post(%Post{} = post, %User{} = user) do
    if first_post?(post) do
      {:error, :first_post}
    else
      changeset = change(post, deleted_at: DateTime.utc_now(:second), deleted_by_id: user.id)

      result =
        logged(fn -> Repo.update(changeset) end, &log_post_delete(user, post, &1))

      tap_ok(result, fn deleted ->
        remove_post_notifications(deleted)
        post_changed(:post_deleted, deleted)
      end)
    end
  end

  defp log_post_delete(user, post, deleted) do
    if staff_on_others?(user, post.user_id),
      do: StaffLog.record(user, "post.delete", deleted, post_details(post))
  end

  @doc "Restores a deleted post as `actor` (admins; see the `:restore_post` policy)."
  def restore_post(%Post{} = post, %User{} = actor) do
    result =
      logged(
        fn -> post |> change(deleted_at: nil, deleted_by_id: nil) |> Repo.update() end,
        &StaffLog.record(actor, "post.restore", &1, post_details(post))
      )

    tap_ok(result, &post_changed(:post_restored, &1))
  end

  # What the staff log keeps about a post, to show it once it's gone.
  defp post_details(%Post{} = post, extra \\ %{}) do
    post = Repo.preload(post, [:thread, :user])

    Map.merge(
      %{
        thread: post.thread.title,
        author: post.user && post.user.username,
        excerpt: String.slice(post.body, 0, 200)
      },
      extra
    )
  end

  defp first_post?(%Post{id: id, thread_id: thread_id}) do
    Post
    |> where([p], p.thread_id == ^thread_id)
    |> order_by([p], asc: p.inserted_at, asc: p.id)
    |> limit(1)
    |> select([p], p.id)
    |> Repo.one() == id
  end

  # Notifications carry the post's body, so they go with it.
  defp remove_post_notifications(%Post{id: post_id}) do
    {_count, user_ids} =
      Notification
      |> where([n], n.post_id == ^post_id)
      |> select([n], n.user_id)
      |> Repo.delete_all()

    user_ids |> Enum.uniq() |> Enum.each(&notifications_changed/1)
  end

  # Thread pages re-render the post; lists refresh their counts.
  defp post_changed(event, %Post{} = post) do
    broadcast("forums:thread:#{post.thread_id}", {event, post})
    broadcast_thread(:thread_activity, get_thread!(post.thread_id))
  end

  @doc """
  Likes `post` as `user` (see the `:like_post` policy). Liking twice is a
  no-op. The author gets one in-app notification per post while it's unread
  ("@bob and 2 others liked your post"), never an email.
  """
  def like_post(%Post{} = post, %User{} = user) do
    like = %PostLike{post_id: post.id, user_id: user.id}

    case Repo.insert(like, on_conflict: :nothing, conflict_target: [:post_id, :user_id]) do
      {:ok, %PostLike{id: nil}} ->
        :ok

      {:ok, _like} ->
        if first_like?(post, user), do: update_like_notification(post, :liked)
        broadcast("forums:thread:#{post.thread_id}", {:post_likes_changed, post})
    end
  end

  @doc "Removes `user`'s like from `post`, if any."
  def unlike_post(%Post{} = post, %User{} = user) do
    PostLike
    |> where([l], l.post_id == ^post.id and l.user_id == ^user.id)
    |> Repo.delete_all()
    |> case do
      {0, _} ->
        :ok

      _ ->
        update_like_notification(post, :unliked)
        broadcast("forums:thread:#{post.thread_id}", {:post_likes_changed, post})
    end
  end

  # Records that the author is being told about this user's like; false if
  # they were told before (the user unliked and liked again).
  defp first_like?(post, user) do
    {count, _} =
      Repo.insert_all(
        "forums_post_like_notices",
        [%{post_id: post.id, user_id: user.id, inserted_at: NaiveDateTime.utc_now()}],
        on_conflict: :nothing,
        conflict_target: [:post_id, :user_id]
      )

    count == 1
  end

  @doc "Whether `user` likes `post`."
  def liked?(%Post{id: post_id}, %User{id: user_id}),
    do: Repo.exists?(from(l in PostLike, where: l.post_id == ^post_id and l.user_id == ^user_id))

  @doc "The users who liked each of `posts`, in order: a map of post id to users."
  def likers(posts) do
    ids = Enum.map(posts, & &1.id)

    PostLike
    |> where([l], l.post_id in ^ids)
    |> join(:inner, [l], u in assoc(l, :user))
    |> order_by([l], asc: l.inserted_at, asc: l.id)
    |> select([l, u], {l.post_id, u})
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Brings the unread "liked" notifications of `post_ids` up to date with
  their remaining likes (after likes were removed in bulk, e.g. by account
  deletion).
  """
  def refresh_like_notifications(post_ids) do
    Post
    |> where([p], p.id in ^post_ids)
    |> Repo.all()
    |> Enum.each(&update_like_notification(&1, :unliked))
  end

  # Brings the author's unread "liked" notification for the post up to date
  # with its current likers: updated, created (only after a like) or removed
  # (when no likes remain). The post row lock serializes concurrent likes, so
  # they share one unread notification.
  defp update_like_notification(%Post{} = post, change) do
    post = Repo.preload(post, [:thread, :user])

    {:ok, changed?} =
      Repo.transact(fn ->
        Post |> where([p], p.id == ^post.id) |> lock("FOR UPDATE") |> Repo.one!()

        likers =
          PostLike
          |> where([l], l.post_id == ^post.id)
          |> join(:inner, [l], u in assoc(l, :user))
          |> order_by([l], desc: l.inserted_at, desc: l.id)
          |> select([l, u], u)
          |> Repo.all()

        unread =
          Notification
          |> where(
            [n],
            n.user_id == ^post.user_id and n.post_id == ^post.id and n.kind == "liked"
          )
          |> where([n], is_nil(n.read_at))
          |> first()
          |> Repo.one()

        {:ok, write_like_notification(unread, likers, post, change)}
      end)

    if changed?, do: notifications_changed(post.user_id)
    :ok
  end

  defp write_like_notification(nil, _likers, _post, :unliked), do: false

  defp write_like_notification(nil, likers, post, :liked) do
    {:ok, _} =
      %Notification{}
      |> Notification.changeset(
        Map.put(Notification.for_likes(post.thread, post, likers), :user_id, post.user_id)
      )
      |> Repo.insert()

    true
  end

  defp write_like_notification(unread, [], _post, _change) do
    {:ok, _} = Repo.delete(unread)
    true
  end

  defp write_like_notification(unread, likers, post, _change) do
    attrs = Notification.for_likes(post.thread, post, likers)
    {:ok, _} = unread |> change(subject: attrs.subject, body: attrs.body) |> Repo.update()
    true
  end

  @doc "A page of `user`'s posts that `viewer` may read, newest first."
  def user_posts(user, viewer, %{page: page}) do
    user
    |> readable_posts_by(viewer)
    |> order_by([p], desc: p.inserted_at)
    |> preload([p], thread: [:category], user: [])
    |> Repo.paginate(page: page)
  end

  @doc "`user`'s latest post that `viewer` may read."
  def user_last_post(user, viewer) do
    user
    |> readable_posts_by(viewer)
    |> order_by([p], desc: p.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  defp readable_posts_by(user, viewer) do
    Post
    |> Post.visible()
    |> where([p], p.user_id == ^user.id)
    |> join(:inner, [p], t in assoc(p, :thread), as: :thread)
    |> Policy.readable_threads(viewer)
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
    threads_query()
    |> where([t], t.id in ^thread_ids)
    |> Policy.readable_threads(user)
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

  @doc """
  The user's notifications, newest first. Like everything else, they leave
  out threads the user may no longer read (say, moved into a restricted
  category).
  """
  def notifications_for(%User{} = user) do
    user
    |> visible_notifications()
    |> order_by(desc: :inserted_at, desc: :id)
    |> limit(100)
    |> Repo.all()
  end

  def unread_notification_count(%User{} = user) do
    user
    |> visible_notifications()
    |> where([n], is_nil(n.read_at))
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
  Whether the user already has an unread, emailed notification about the
  same thread or conversation as `notification`. Used to send one email per
  thread (or conversation) until the user comes back.
  """
  def unread_emailed_notification?(%User{} = user, %Notification{} = notification) do
    about =
      if notification.conversation_id,
        do: dynamic([n], n.conversation_id == ^notification.conversation_id),
        else: dynamic([n], n.thread_id == ^notification.thread_id)

    Notification
    |> where([n], n.user_id == ^user.id and n.id != ^notification.id)
    |> where(^about)
    |> where([n], is_nil(n.read_at) and not is_nil(n.emailed_at))
    |> Repo.exists?()
  end

  defp visible_notifications(user) do
    readable = threads_query() |> Policy.readable_threads(user) |> select([t], t.id)

    Notification
    |> where([n], n.user_id == ^user.id)
    |> where([n], is_nil(n.thread_id) or n.thread_id in subquery(readable))
  end

  def notifications_topic(user_id), do: "user:#{user_id}:notifications"

  @doc """
  Tells the user's open pages their notifications (or unread messages)
  changed, so the badges update.
  """
  def notifications_changed(user_id) do
    Phoenix.PubSub.broadcast(
      FirestormWeb.PubSub,
      notifications_topic(user_id),
      :notifications_changed
    )
  end

  @doc "One of `user`'s notifications (see `notifications_for/1`), or nil."
  def get_notification(%User{} = user, id) do
    user
    |> visible_notifications()
    |> Repo.get(id)
  end

  def decorate_post_oembeds(%Post{deleted_at: %DateTime{}} = post), do: %Post{post | oembeds: []}

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
  #   * "forums:thread:<id>"      - {:post_created | :post_updated | :post_deleted | :post_restored | :post_likes_changed, post} and the thread events for that thread

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
