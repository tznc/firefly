defmodule FirestormWeb.Forums.Policy do
  @moduledoc """
  Authorization rules for the Forums context (see `Bodyguard.Policy`).

    * `:manage_category` (create, edit, delete) - admins
    * `:update_thread`, `:delete_thread` - the thread's author (unless it's
      archived) and admins
    * `:moderate_thread` (pin, close, archive, move) - admins
    * `:edit_post`, `:delete_post` (params `%{post: post, thread: thread}`) -
      the post's author while the thread is open (editing, also only within
      the `edit_grace_minutes` site setting; 0: forever), and admins; not
      once the post is deleted. (`Forums.delete_post/2` also refuses a thread's first
      post: delete the thread instead.)
    * `:restore_post`, `:view_deleted_posts` - admins
    * `:penalize_user` (silence or suspend; params: the user) - admins, on
      users who aren't admins
    * `:lift_penalty` (params: the user) - admins, on anyone (a penalized
      member may have been made an admin since)
    * `:like_post` (params `%{post: post, thread: thread}`) - members, on other
      people's posts that aren't deleted, unless the thread is archived
    * `:flag_post` (same params) - members, on other people's posts that
      aren't deleted or already hidden
    * `:view_hidden_post` (params: the post) - its author and admins
    * `:view_flags` (flag counts and reasons), `:unhide_post`, `:review` (the
      review queue) - admins
    * `:edit_user` - the user themselves
    * `:view_conversation` (a private conversation: read and reply) - its
      participants, until they leave. Nobody else, admins included.
    * `:add_participants` - participants who started the conversation, and
      admin participants
    * `:view_staff_log`, `:manage_site_settings`, `:manage_groups` - admins
    * `:view_category`, `:view_thread` (in its category) - everyone, members
      or not, unless the category is restricted to roles (groups): then
      members of one of those roles, and admins. A subcategory also needs its
      parent's roles, if the parent is restricted. A thread awaiting
      approval (see `FirestormWeb.Review`) is only for its author and
      admins. Every way of reading a
      thread (pages, lists, search, notifications, email, the API) goes
      through these rules or their query counterparts, `readable_threads/2`
      and `readable_categories/2`: keep them in step.
  """

  @behaviour Bodyguard.Policy

  import Ecto.Query

  alias FirestormWeb.{Forums, Messages, Repo, SiteSettings}
  alias FirestormWeb.Forums.{Category, Conversation, Post, Role, RoleMembership, Thread, User}

  @impl true
  def authorize(:view_thread, user, %Thread{category_id: category_id} = thread) do
    with :ok <- visible(user, category_id), do: approved_or_own(user, thread)
  end

  def authorize(:view_category, user, %Category{id: id}), do: visible(user, id)

  def authorize(_action, nil, _params), do: {:error, :unauthenticated}

  def authorize(:edit_user, %User{id: id}, %{user: %{id: id}}), do: :ok

  def authorize(:view_conversation, %User{} = user, %Conversation{} = conversation),
    do: if(Messages.participant?(conversation, user), do: :ok, else: {:error, :unauthorized})

  def authorize(:add_participants, %User{} = user, %Conversation{} = conversation) do
    cond do
      not Messages.participant?(conversation, user) -> {:error, :unauthorized}
      conversation.user_id == user.id -> :ok
      true -> admin(user)
    end
  end

  def authorize(:manage_category, %User{} = user, _params), do: admin(user)

  def authorize(:penalize_user, %User{} = user, %User{} = target),
    do: if(Forums.admin?(target), do: {:error, :unauthorized}, else: admin(user))

  def authorize(:lift_penalty, %User{} = user, %User{}), do: admin(user)

  def authorize(:moderate_thread, %User{} = user, _params), do: admin(user)

  # Archived threads are read-only, except to admins.
  def authorize(action, %User{} = user, %Thread{} = thread)
      when action in [:update_thread, :delete_thread] do
    if Forums.thread_author_id(thread) == user.id and not Thread.archived?(thread),
      do: :ok,
      else: admin(user)
  end

  def authorize(action, %User{} = user, %{post: %Post{} = post, thread: %Thread{} = thread})
      when action in [:edit_post, :delete_post] do
    cond do
      Post.deleted?(post) -> {:error, :unauthorized}
      post.user_id == user.id and not Thread.closed?(thread) and in_window?(action, post) -> :ok
      true -> admin(user)
    end
  end

  def authorize(:like_post, %User{} = user, %{post: %Post{} = post, thread: %Thread{} = thread}) do
    if post.user_id != user.id and not Post.deleted?(post) and not Thread.archived?(thread),
      do: :ok,
      else: {:error, :unauthorized}
  end

  def authorize(:flag_post, %User{} = user, %{post: %Post{} = post, thread: %Thread{}}) do
    if post.user_id != user.id and not Post.deleted?(post) and not Post.hidden?(post) and
         not Post.queued?(post),
       do: :ok,
       else: {:error, :unauthorized}
  end

  def authorize(:view_hidden_post, %User{id: id}, %Post{user_id: id}), do: :ok

  def authorize(action, %User{} = user, _params)
      when action in [
             :view_hidden_post,
             :view_flags,
             :review,
             :unhide_post,
             :restore_post,
             :view_deleted_posts,
             :view_staff_log,
             :manage_site_settings,
             :manage_groups
           ],
      do: admin(user)

  # Catch-all: deny everything else
  def authorize(_action, _user, _params), do: {:error, :unauthorized}

  defp in_window?(:delete_post, _post), do: true

  defp in_window?(:edit_post, post) do
    case SiteSettings.get("edit_grace_minutes") do
      0 -> true
      minutes -> NaiveDateTime.diff(NaiveDateTime.utc_now(), post.inserted_at, :minute) < minutes
    end
  end

  defp admin(user), do: if(Forums.admin?(user), do: :ok, else: {:error, :unauthorized})

  # A thread awaiting approval is for its author and admins.
  defp approved_or_own(user, thread) do
    case Forums.queued_thread_author_id(thread) do
      nil -> :ok
      author_id when is_struct(user, User) and user.id == author_id -> :ok
      _author_id -> if staff?(user), do: :ok, else: {:error, :unauthorized}
    end
  end

  defp visible(user, category_id) do
    if category_visible?(user, category_id), do: :ok, else: {:error, :unauthorized}
  end

  defp category_visible?(user, category_id) do
    staff?(user) or
      not Repo.exists?(where(hidden_category_ids(user), [c], c.id == ^category_id))
  end

  defp staff?(nil), do: false
  defp staff?(%User{} = user), do: Forums.admin?(user)

  @doc """
  The `users` who may read `thread`, as the `:view_thread` rule decides for
  each, in a query or two however many users there are (for the
  notification fan-out). A thread in an unrestricted category: all of them.
  """
  def thread_readers(%Thread{category_id: category_id}, users) do
    restricted =
      Repo.all(
        from(cr in "forums_category_roles",
          join: c in Category,
          on: c.id == ^category_id and (cr.category_id == c.id or cr.category_id == c.parent_id),
          distinct: true,
          select: cr.category_id
        )
      )

    if restricted == [] or users == [] do
      users
    else
      ids = Enum.map(users, & &1.id)

      query =
        from(u in User,
          as: :user,
          where: u.id in ^ids,
          where: ^readers_condition(restricted),
          select: u.id
        )

      readers = MapSet.new(Repo.all(query))

      Enum.filter(users, &MapSet.member?(readers, &1.id))
    end
  end

  # Admins, or members of one of the roles of every restricted category on
  # the way (the category and its parent).
  defp readers_condition(restricted) do
    admin =
      from(m in RoleMembership,
        join: r in Role,
        on: r.id == m.role_id,
        where: m.user_id == parent_as(:user).id and r.name == "admin",
        select: 1
      )

    member =
      Enum.reduce(restricted, dynamic(true), fn category_id, acc ->
        in_role =
          from(m in RoleMembership,
            join: cr in "forums_category_roles",
            on: cr.role_id == m.role_id,
            where: m.user_id == parent_as(:user).id and cr.category_id == ^category_id,
            select: 1
          )

        dynamic(^acc and exists(in_role))
      end)

    dynamic(exists(admin) or ^member)
  end

  @doc """
  Restricts `query` to threads `user` (or nil, a visitor) may read, as the
  `:view_thread` rule does for one thread. The query must bind the thread
  as `:thread`.
  """
  def readable_threads(query, user) do
    if staff?(user),
      do: query,
      else: where(query, [thread: t], t.category_id not in subquery(hidden_category_ids(user)))
  end

  @doc """
  Restricts a query of categories (the first binding) to those `user` may
  read, as the `:view_category` rule does for one.
  """
  def readable_categories(query, user) do
    if staff?(user),
      do: query,
      else: where(query, [c], c.id not in subquery(hidden_category_ids(user)))
  end

  @doc """
  The ids of the categories closed to `user` (ignoring that admins see
  everything), as a query: those restricted to roles the user isn't in,
  and their subcategories. For a visitor (nil), every restricted category.
  """
  def hidden_category_ids(user) do
    member_of =
      from(cr in "forums_category_roles",
        where: cr.role_id in subquery(role_ids(user)),
        select: cr.category_id
      )

    closed =
      from(cr in "forums_category_roles",
        where: cr.category_id not in subquery(member_of),
        select: cr.category_id
      )

    from(c in Category,
      where: c.id in subquery(closed) or c.parent_id in subquery(closed),
      select: c.id
    )
  end

  defp role_ids(nil), do: from(m in RoleMembership, where: false, select: m.role_id)

  defp role_ids(%User{id: user_id}),
    do: from(m in RoleMembership, where: m.user_id == ^user_id, select: m.role_id)
end
