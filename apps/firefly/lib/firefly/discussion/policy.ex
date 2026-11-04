defmodule Firefly.Discussion.Policy do
  @moduledoc """
  Authorization rules for the Discussion context (see `Bodyguard.Policy`).

  Staff are admins and moderators (see `Firefly.Accounts.staff?/1`).
  Moderators look after members and content (the review queue, flags,
  penalties, new accounts, thread moderation, others' posts); admins also
  run the site (settings, groups, categories, plugins and the rest).

    * `:manage_category` (create, edit, delete) - admins
    * `:create_thread` (params: the category), `:reply_thread` (params:
      the thread) - in a restricted category, members of a group whose
      permission there allows it (`full` starts threads and replies,
      `create_post` only replies, `readonly` neither; a subcategory
      without groups of its own follows its parent's), and staff; in an
      open category, everyone (reading is `:view_category`'s business)
    * `:update_thread` (rename, retag), `:delete_thread` - the thread's
      author (unless it's archived) and staff; renaming and retagging
      also regulars (trust level 3, see `Firefly.TrustLevels`), on
      threads that aren't archived
    * `:move_thread` (to another category) - staff, and regulars on
      threads that aren't archived
    * `:close_thread` (pin, close; params: the thread) - staff and leaders
      (trust level 4)
    * `:moderate_thread` (pin, close, archive, move) - staff; a plugin's bot
      with the `moderate` permission, on a thread anyone can read
    * `:tag_thread` (a plugin changing a thread's tags) - a plugin's bot with
      the `tags` permission, on a thread anyone can read
    * `:edit_post`, `:delete_post` (params `%{post: post, thread: thread}`) -
      the post's author while the thread is open (editing, also only within
      the `edit_grace_minutes` site setting; 0: forever), and staff; not
      once the post is deleted. Leaders (trust level 4) edit others' posts
      too. Authors can't edit a post while it awaits
      approval. A wiki post (`Post.wiki?/1`) can also be edited, with no
      time limit, by any member at `min_trust_to_edit_wiki` who may read
      it and its thread while the thread is open; saving still goes through `Posting.check/2` (penalties,
      slow mode). (`Discussion.delete_post/2` also refuses a thread's first
      post: delete the thread instead.)
    * `:toggle_wiki` (make a post a wiki or not) - staff and leaders
    * `:accept_answer` (mark a reply as the accepted answer, or unmark it;
      params: the thread) - in a category that allows accepted answers, the
      thread's author unless it's archived, and admins; never on a merged
      stub. Which replies qualify is `Firefly.Discussion.Solved`'s business.
    * `:vote_poll` (params `%{post: post, thread: thread}`) - members, on a
      published post (not deleted, hidden or awaiting approval) in a thread
      that isn't archived or merged. (`Firefly.Discussion.Polls` also checks the
      poll is open and the voter may read the thread.)
    * `:manage_poll` (close and reopen; same params) - the post's author,
      unless it's deleted or the thread archived, and admins
    * `:penalize_user` (silence or suspend; params: the user) - staff, on
      users who aren't staff
    * `:lift_penalty` (params: the user) - staff, on anyone (a penalized
      member may have been made staff since)
    * `:impersonate` (params: the user) - admins, on members who aren't
      staff, deleted or suspended, and not themselves
    * `:reset_two_factor`, `:set_trust_level` (params: the user) - admins,
      on anyone
    * `:like_post` (params `%{post: post, thread: thread}`) - members, on other
      people's posts that aren't deleted, unless the thread is archived
    * `:flag_post` (same params) - members at `min_trust_to_flag`, on other
      people's posts that aren't deleted or already hidden
    * `:view_hidden_post` (params: the post) - its author and staff
    * `:view_flags` (flag counts and reasons), `:unhide_post`, `:review` (the
      review queue), `:restore_post`, `:view_deleted_posts`,
      `:view_staff_log`, `:view_admin` (the staff admin at `/staff`),
      `:view_users` (the users admin), `:approve_user` (approve or reject
      accounts waiting for approval), `:manage_screening` (screened emails,
      IPs and URLs) - staff
    * `:edit_user` - the user themselves
    * `:view_conversation` (a private conversation: read and reply) - its
      participants, until they leave, and the members of the group it was
      sent to. Nobody else, admins included.
    * `:add_participants` - participants who started the conversation, and
      admin participants
    * `:manage_site_settings`, `:manage_users` (edit, anonymize, delete,
      merge, roles, password resets, notifications), `:manage_emails` (the
      email log, test emails and previews), `:manage_themes` (themes and
      their components, scripts included, see `Firefly.Themes`), `:manage_groups`,
      `:manage_tags` (tag groups and synonyms), `:manage_badges`, `:manage_plugins`,
      `:manage_uploads` (list and delete any upload), `:manage_emoji`
      (custom emoji), `:manage_watched_words`, `:manage_webhooks`,
      `:manage_api_keys` (every API key, and global keys),
      `:manage_sso_clients` (the DiscourseConnect provider's sites),
      `:view_reports` (the dashboard and reports), `:manage_backups` (and
      read-only mode), `:manage_imports` (the import runs, see
      `Firefly.Import`), `:manage_upgrades` (the upgrade page),
      `:manage_embedding` (embeddable hosts), `:manage_ai` (AI providers
      and features, see `Firefly.AI`) - admins
    * `:manage_database` (the raw records admin at `/staff/db`) - admins,
      while the `enable_database_admin` setting is on
    * `:view_category`, `:view_thread` (in its category) - everyone, members
      or not, unless the category is restricted to roles (groups): then
      members of one of those roles, and staff. A subcategory also needs its
      parent's roles, if the parent is restricted. A thread awaiting
      approval (see `Firefly.Moderation.Review`) is only for its author and
      staff. Every way of reading a
      thread (pages, lists, search, notifications, email, the API) goes
      through these rules or their query counterparts, `readable_threads/2`
      and `readable_categories/2`: keep them in step.
  """

  @behaviour Bodyguard.Policy

  import Ecto.Query

  alias Firefly.{Accounts, Discussion, Messaging, Repo, SiteSettings, TrustLevels}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Category, Post, Thread}
  alias Firefly.Groups.{Role, RoleMembership}
  alias Firefly.Messaging.Conversation

  @impl true
  def authorize(:view_thread, user, %Thread{category_id: category_id} = thread) do
    with :ok <- visible(user, category_id), do: approved_or_own(user, thread)
  end

  def authorize(:view_category, user, %Category{id: id}), do: visible(user, id)

  def authorize(_action, nil, _params), do: {:error, :unauthenticated}

  def authorize(:edit_user, %User{id: id}, %{user: %{id: id}}), do: :ok

  def authorize(:create_thread, %User{} = user, %Category{id: id}),
    do: category_permission(user, id, ~w(full))

  def authorize(:reply_thread, %User{} = user, %Thread{category_id: id}),
    do: category_permission(user, id, ~w(full create_post))

  def authorize(:view_conversation, %User{} = user, %Conversation{} = conversation),
    do: if(Messaging.reader?(conversation, user), do: :ok, else: {:error, :unauthorized})

  def authorize(:add_participants, %User{} = user, %Conversation{} = conversation) do
    cond do
      not Messaging.participant?(conversation, user) -> {:error, :unauthorized}
      conversation.user_id == user.id -> :ok
      true -> admin(user)
    end
  end

  def authorize(:manage_category, %User{} = user, _params), do: admin(user)

  def authorize(:penalize_user, %User{} = user, %User{} = target),
    do: if(Accounts.staff?(target), do: {:error, :unauthorized}, else: staff(user))

  def authorize(:lift_penalty, %User{} = user, %User{}), do: staff(user)

  # Seeing the site as someone else: admins, as members who aren't staff
  # (and whose account is usable).
  def authorize(:impersonate, %User{id: id}, %User{id: id}), do: {:error, :unauthorized}

  def authorize(:impersonate, %User{} = user, %User{} = target) do
    if Accounts.staff?(target) or User.deleted?(target) or User.suspended?(target),
      do: {:error, :unauthorized},
      else: admin(user)
  end

  def authorize(:reset_two_factor, %User{} = user, %User{}), do: admin(user)

  # A plugin's bot (see Firefly.Plugins.Bots) moderates and tags as its
  # plugin's permissions allow, and only threads anyone can read.
  def authorize(action, %User{plugin_bot: plugin_id}, %Thread{} = thread)
      when is_binary(plugin_id) and action in [:moderate_thread, :tag_thread] do
    permission = if action == :moderate_thread, do: "moderate", else: "tags"

    if Firefly.Plugins.permitted?(plugin_id, permission) and
         authorize(:view_thread, nil, thread) == :ok,
       do: :ok,
       else: {:error, :unauthorized}
  end

  def authorize(:moderate_thread, %User{} = user, _params), do: staff(user)

  # Archived threads are read-only, except to staff.
  def authorize(action, %User{} = user, %Thread{} = thread)
      when action in [:update_thread, :delete_thread] do
    cond do
      Thread.archived?(thread) -> staff(user)
      Discussion.thread_author_id(thread) == user.id -> :ok
      action == :update_thread -> trusted(user, 3)
      true -> staff(user)
    end
  end

  def authorize(:move_thread, %User{} = user, %Thread{} = thread),
    do: if(Thread.archived?(thread), do: staff(user), else: trusted(user, 3))

  def authorize(:close_thread, %User{} = user, %Thread{}), do: trusted(user, 4)
  def authorize(:toggle_wiki, %User{} = user, _params), do: trusted(user, 4)

  def authorize(action, %User{} = user, %{post: %Post{} = post, thread: %Thread{} = thread})
      when action in [:edit_post, :delete_post] do
    cond do
      Post.deleted?(post) -> {:error, :unauthorized}
      action == :edit_post -> may_edit(user, post, thread)
      post.user_id == user.id and not Thread.closed?(thread) -> :ok
      true -> staff(user)
    end
  end

  def authorize(:accept_answer, %User{} = user, %Thread{} = thread) do
    cond do
      Thread.merged?(thread) or not accepts_answers?(thread) -> {:error, :unauthorized}
      Discussion.thread_author_id(thread) == user.id and not Thread.archived?(thread) -> :ok
      true -> admin(user)
    end
  end

  def authorize(:vote_poll, %User{}, %{post: %Post{} = post, thread: %Thread{} = thread}) do
    if Post.readable_by?(post, nil) and not Thread.archived?(thread) and
         not Thread.merged?(thread),
       do: :ok,
       else: {:error, :unauthorized}
  end

  def authorize(:manage_poll, %User{} = user, %{post: %Post{} = post, thread: %Thread{} = thread}) do
    if post.user_id == user.id and not Post.deleted?(post) and not Thread.archived?(thread),
      do: :ok,
      else: admin(user)
  end

  def authorize(:like_post, %User{} = user, %{post: %Post{} = post, thread: %Thread{} = thread}) do
    if post.user_id != user.id and not Post.deleted?(post) and not Thread.archived?(thread),
      do: :ok,
      else: {:error, :unauthorized}
  end

  def authorize(:flag_post, %User{} = user, %{post: %Post{} = post, thread: %Thread{}}) do
    if post.user_id != user.id and not Post.deleted?(post) and not Post.hidden?(post) and
         not Post.queued?(post) and TrustLevels.allowed?(user, "min_trust_to_flag"),
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
             :view_admin,
             :view_users,
             :approve_user,
             :manage_screening
           ],
      do: staff(user)

  def authorize(action, %User{} = user, _params)
      when action in [
             :manage_site_settings,
             :manage_users,
             :manage_emails,
             :manage_themes,
             :manage_groups,
             :manage_tags,
             :manage_plugins,
             :manage_uploads,
             :manage_emoji,
             :manage_watched_words,
             :manage_webhooks,
             :manage_api_keys,
             :manage_sso_clients,
             :view_reports,
             :manage_backups,
             :manage_imports,
             :manage_upgrades,
             :manage_embedding,
             :manage_ai,
             :manage_badges,
             :set_trust_level
           ],
      do: admin(user)

  def authorize(:manage_database, %User{} = user, _params) do
    if SiteSettings.get("enable_database_admin"), do: admin(user), else: {:error, :unauthorized}
  end

  # Catch-all: deny everything else
  def authorize(_action, _user, _params), do: {:error, :unauthorized}

  defp wiki_editable?(user, post, thread) do
    Post.wiki?(post) and not Thread.closed?(thread) and not Thread.merged?(thread) and
      TrustLevels.allowed?(user, "min_trust_to_edit_wiki") and Post.readable_by?(post, user) and
      authorize(:view_thread, user, thread) == :ok
  end

  defp may_edit(user, post, thread) do
    cond do
      # Staff approve what they saw: no author edits while it's queued.
      Post.queued?(post) -> staff(user)
      post.user_id == user.id and not Thread.closed?(thread) and in_window?(post) -> :ok
      wiki_editable?(user, post, thread) -> :ok
      true -> trusted(user, 4)
    end
  end

  defp in_window?(post) do
    case SiteSettings.get("edit_grace_minutes") do
      0 -> true
      minutes -> NaiveDateTime.diff(NaiveDateTime.utc_now(), post.inserted_at, :minute) < minutes
    end
  end

  # Read now: the category's setting may have changed since `thread` was.
  defp accepts_answers?(%Thread{category_id: category_id}) do
    Repo.exists?(from(c in Category, where: c.id == ^category_id and c.allow_accepted_answers))
  end

  defp admin(user), do: if(Accounts.admin?(user), do: :ok, else: {:error, :unauthorized})
  defp staff(user), do: if(Accounts.staff?(user), do: :ok, else: {:error, :unauthorized})

  # Posting in a restricted category: its groups' permissions (or, for a
  # subcategory without groups of its own, its parent's) must allow it for
  # one of the user's groups. Open categories and staff: always.
  defp category_permission(user, category_id, allowed) do
    grants = category_grants(category_id)
    role_ids = for {role_id, permission} <- grants, permission in allowed, do: role_id

    if grants == [] or staff?(user) or in_any_role?(user, role_ids),
      do: :ok,
      else: {:error, :unauthorized}
  end

  # `{role_id, permission}` of the category's own groups, else its parent's.
  defp category_grants(category_id) do
    rows =
      Repo.all(
        from(cr in "forums_category_roles",
          join: c in Category,
          on: c.id == ^category_id and (cr.category_id == c.id or cr.category_id == c.parent_id),
          select: {cr.category_id == c.id, cr.role_id, cr.permission}
        )
      )

    case for({true, role_id, permission} <- rows, do: {role_id, permission}) do
      [] -> for {false, role_id, permission} <- rows, do: {role_id, permission}
      own -> own
    end
  end

  defp in_any_role?(_user, []), do: false

  defp in_any_role?(user, role_ids),
    do:
      Repo.exists?(
        from(m in RoleMembership, where: m.user_id == ^user.id and m.role_id in ^role_ids)
      )

  # Admins, and members at `level` or above.
  defp trusted(user, level),
    do: if(TrustLevels.at_least?(user, level), do: :ok, else: {:error, :unauthorized})

  # A thread awaiting approval is for its author and staff.
  defp approved_or_own(user, thread) do
    case Discussion.queued_thread_author_id(thread) do
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
  defp staff?(%User{} = user), do: Accounts.staff?(user)

  @doc """
  The `users` who may read `thread`, as the `:view_thread` rule decides for
  each, in a query or two however many users there are (for the
  notification fan-out). A thread in an unrestricted category: all of them
  (unless it awaits approval: then its author and staff).
  """
  def thread_readers(%Thread{} = thread, users) do
    readers = category_readers(thread, users)

    case Discussion.queued_thread_author_id(thread) do
      nil -> readers
      author_id -> Enum.filter(readers, &(&1.id == author_id or Accounts.staff?(&1)))
    end
  end

  defp category_readers(%Thread{category_id: category_id}, users) do
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
        where: m.user_id == parent_as(:user).id and r.name in ["admin", "moderator"],
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
  The ids of the categories closed to `user` (ignoring that staff see
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
