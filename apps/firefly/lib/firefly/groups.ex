defmodule Firefly.Groups do
  @moduledoc """
  Groups are roles (`Firefly.Groups.Role`): admins create them and set
  them up at `/staff/groups`, and can restrict
  categories to them (see `Firefly.Discussion.Policy`).

  Each group has a page (`/groups/:name`: about, members, its members'
  recent posts, and for members its inbox), shown to whom its `visibility`
  allows. People join as its `membership` mode allows: owners and staff add
  members to any group; anyone joins an `open` one; anyone asks to join a
  `request` one, and its owners (or, without owners, the admins) are
  notified and approve or deny; owners invite people to an `invite` one,
  and the invitee accepts. Members leave when they like.

  Owners manage the group's members, requests, invitations and About text;
  admins also its settings and owners. Member changes go to the staff log,
  in the same transaction, as the acting owner's or admin's (or the
  system's, for DiscourseConnect sync).

  A group is @mentioned (`@name`, see `Firefly.Discussion.Mentions`) and messaged
  (its inbox, see `Firefly.Messaging`) by whom its `mentionable` and
  `messageable` levels allow: `owners`, `members`, `everyone`, or `nobody`
  but staff. The "admin" group is staff: it stays closed, staff-only, and
  only admins change its members. Trust level groups' members follow
  their trust level (see `Firefly.TrustLevels`): nobody adds,
  removes, invites or makes owners there (`{:error, :automatic}`).
  """

  use Boundary, top_level?: true, check: [out: false], exports: [Role, RoleMembership]

  import Ecto.Query

  alias Firefly.{Accounts, Groups, Notifications, Repo}
  alias Firefly.Moderation.StaffLog
  alias Firefly.Accounts.User
  alias Firefly.Discussion.Post
  alias Firefly.Groups.{GroupRequest, Role, RoleMembership}
  alias Firefly.Notifications.Notification

  ## Listing and finding

  @doc "Every group by name, with its members (by username) and restricted categories."
  def list_groups do
    members = from(u in User, order_by: u.username)

    Role
    |> order_by(:name)
    |> preload(users: ^members)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :categories, categories(&1)))
  end

  defp categories(%Role{id: role_id}) do
    Repo.all(
      from(c in Firefly.Discussion.Category,
        join: cr in "forums_category_roles",
        on: cr.category_id == c.id,
        where: cr.role_id == ^role_id,
        order_by: c.title
      )
    )
  end

  @doc "The groups `viewer` (nil: a visitor) may see, by name, with member counts."
  def list_visible(viewer) do
    Role
    |> visible_query(viewer)
    |> order_by(:name)
    |> join(:left, [r], m in RoleMembership, on: m.role_id == r.id)
    |> group_by([r], r.id)
    |> select([r, m], {r, count(m.id)})
    |> Repo.all()
  end

  defp visible_query(query, viewer) do
    cond do
      admin?(viewer) ->
        query

      is_nil(viewer) ->
        where(query, [r], r.visibility == "public")

      true ->
        mine = from(m in RoleMembership, where: m.user_id == ^viewer.id, select: m.role_id)

        where(
          query,
          [r],
          r.visibility == "public" or (r.visibility == "members" and r.id in subquery(mine))
        )
    end
  end

  @doc "Gets a group by id. Raises `Ecto.NoResultsError` if there's none."
  def get_group!(id), do: Repo.get!(Role, id)

  @doc "The group named `name` (any case), or nil."
  def get_by_name(name) when is_binary(name),
    do: Repo.one(from(r in Role, where: fragment("lower(?)", r.name) == ^String.downcase(name)))

  @doc "The groups named in `names` (any case), by lowercased name."
  def by_names([]), do: %{}

  def by_names(names) do
    lowered = Enum.map(names, &String.downcase/1)

    groups = Repo.all(from(r in Role, where: fragment("lower(?)", r.name) in ^lowered))
    Map.new(groups, &{String.downcase(&1.name), &1})
  end

  def change_group(attrs \\ %{}), do: Role.changeset(%Role{}, attrs)

  ## Who may do what

  defp admin?(nil), do: false
  defp admin?(user), do: Accounts.admin?(user)

  defp membership(%Role{id: role_id}, %User{id: user_id}),
    do: Repo.get_by(RoleMembership, role_id: role_id, user_id: user_id)

  defp membership(_role, nil), do: nil

  @doc "Whether `user` is in the group."
  def member?(role, user), do: membership(role, user) != nil

  @doc "Whether `user` owns the group."
  def owner?(role, user), do: match?(%RoleMembership{owner: true}, membership(role, user))

  @doc "Whether `viewer` (nil: a visitor) may see the group, its page and members."
  def visible?(%Role{visibility: "public"}, _viewer), do: true

  def visible?(%Role{visibility: "members"} = role, viewer),
    do: member?(role, viewer) or admin?(viewer)

  def visible?(%Role{}, viewer), do: admin?(viewer)

  @doc "Whether `user` manages the group's members: its owners and admins (only admins for the staff groups)."
  def manager?(%Role{name: name}, user) when name in ~w(admin moderator), do: admin?(user)
  def manager?(role, user), do: admin?(user) or owner?(role, user)

  @doc "Whether `user` may @mention the group (see the moduledoc)."
  def can_mention?(%Role{mentionable: level} = role, user), do: allowed?(level, role, user)

  @doc "Whether `user` may message the group's inbox."
  def can_message?(%Role{messageable: level} = role, user), do: allowed?(level, role, user)

  defp allowed?(_level, _role, nil), do: false

  defp allowed?(level, role, user) do
    admin?(user) or
      case level do
        "everyone" -> true
        "members" -> member?(role, user)
        "owners" -> owner?(role, user)
        "nobody" -> false
      end
  end

  ## Members

  @doc "The group's members, owners first, then by username, with `owner` set."
  def members(%Role{id: role_id}) do
    Repo.all(
      from(u in User,
        join: m in RoleMembership,
        on: m.user_id == u.id and m.role_id == ^role_id,
        order_by: [desc: m.owner, asc: u.username],
        select: {u, m.owner}
      )
    )
  end

  @doc "The members (users) to notify of the group's activity, with their membership."
  def memberships(%Role{id: role_id}) do
    Repo.all(
      from(m in RoleMembership,
        join: u in assoc(m, :user),
        where: m.role_id == ^role_id and is_nil(u.deleted_at),
        preload: [user: u]
      )
    )
  end

  @doc "Creates a group (a role) as `actor`."
  def create_group(attrs, %User{} = actor) do
    Repo.transact(fn ->
      with {:ok, role} <- %Role{} |> Role.changeset(attrs) |> Repo.insert() do
        StaffLog.record(actor, "role.create", {"role", role.id}, %{role: role.name})
        {:ok, role}
      end
    end)
  end

  @doc "Changes the group's settings as `admin` (staff-logged)."
  def update_settings(%Role{} = role, attrs, %User{} = admin) do
    Repo.transact(fn ->
      with {:ok, updated} <- role |> Role.settings_changeset(attrs) |> Repo.update() do
        changes = Map.take(updated, [:visibility, :membership, :mentionable, :messageable])

        StaffLog.record(
          admin,
          "role.update",
          {"role", role.id},
          Map.put(changes, :role, role.name)
        )

        {:ok, updated}
      end
    end)
  end

  @doc """
  Renames the group as `admin` (staff-logged as `role.update`). The staff
  and trust level groups keep their names (`{:error, :reserved}`): the
  site finds them by name.
  """
  def rename_group(%Role{} = role, name, %User{} = admin) do
    if Role.staff?(role) or Role.automatic?(role),
      do: {:error, :reserved},
      else: Repo.transact(fn -> rename(role, name, admin) end)
  end

  defp rename(role, name, admin) do
    with {:ok, renamed} <- role |> Role.changeset(%{name: name}) |> Repo.update(),
         do: {:ok, log_rename(role, renamed, admin)}
  end

  defp log_rename(%Role{name: same}, %Role{name: same} = renamed, _admin), do: renamed

  defp log_rename(role, renamed, admin) do
    StaffLog.record(admin, "role.update", {"role", role.id}, %{
      role: renamed.name,
      name: %{before: role.name, after: renamed.name}
    })

    renamed
  end

  @doc """
  Deletes the group and its memberships as `admin` (staff-logged). The
  staff and trust level groups can't be deleted (`{:error, :reserved}`),
  nor a group a category is restricted to (`{:error, :in_use}`): lifting
  that restriction is a decision to make on the category.
  """
  def delete_group(%Role{} = role, %User{} = admin) do
    cond do
      Role.staff?(role) or Role.automatic?(role) ->
        {:error, :reserved}

      Repo.exists?(from(cr in "forums_category_roles", where: cr.role_id == ^role.id)) ->
        {:error, :in_use}

      true ->
        Repo.transact(fn ->
          {members, _} = Repo.delete_all(from(m in RoleMembership, where: m.role_id == ^role.id))
          Repo.delete!(role)

          StaffLog.record(admin, "role.delete", {"role", role.id}, %{
            role: role.name,
            members: members
          })

          {:ok, role}
        end)
    end
  end

  @doc """
  The staff group named `name` (`"admin"` or `"moderator"`), created
  closed and staff-only the first time it's needed.
  """
  def staff_group(name) when name in ~w(admin moderator) do
    case get_by_name(name) do
      %Role{} = role ->
        role

      nil ->
        {:ok, role} = create_role(name)
        role
    end
  end

  @doc "Changes the About text, as an owner or admin."
  def update_description(%Role{} = role, attrs, %User{} = actor) do
    if manager?(role, actor),
      do: role |> Role.description_changeset(attrs) |> Repo.update(),
      else: {:error, :unauthorized}
  end

  @doc """
  Adds the user named `username` to the group, as `actor` (an owner or
  admin). Errors: `:no_such_user`, `:already_member`, `:unauthorized`.
  """
  def add_member(%Role{} = role, username, %User{} = actor) do
    with :ok <- manual(role),
         :ok <- authorize_manager(role, actor),
         {:ok, user} <- find_user(username) do
      if member?(role, user), do: {:error, :already_member}, else: grant(role, user, actor)
    end
  end

  defp manual(role), do: if(Role.automatic?(role), do: {:error, :automatic}, else: :ok)

  defp authorize_manager(role, actor),
    do: if(manager?(role, actor), do: :ok, else: {:error, :unauthorized})

  defp find_user(username) do
    name = username |> to_string() |> String.trim() |> String.trim_leading("@")

    case [String.downcase(name)] |> Accounts.users_by_username() |> Map.values() do
      [] -> {:error, :no_such_user}
      [user] -> {:ok, user}
    end
  end

  defp grant(role, user, actor) do
    Repo.transact(fn ->
      {:ok, _} = Groups.add_role(user, role)

      Repo.delete_all(
        from(r in GroupRequest, where: r.role_id == ^role.id and r.user_id == ^user.id)
      )

      StaffLog.record(actor, "role.grant", user, %{role: role.name, username: user.username})
      {:ok, user}
    end)
  end

  @doc """
  Removes `user` from the group, as `actor` (an owner or admin, or the user
  themselves). Admins can't take themselves out of "admin"
  (`{:error, :own_admin}`): someone else has to.
  """
  def remove_member(%Role{name: "admin"}, %User{id: id}, %User{id: id}),
    do: {:error, :own_admin}

  def remove_member(%Role{} = role, %User{} = user, %User{} = actor) do
    cond do
      Role.automatic?(role) ->
        {:error, :automatic}

      actor.id == user.id or manager?(role, actor) ->
        Repo.transact(fn -> revoke(role, user, actor) end)

      true ->
        {:error, :unauthorized}
    end
  end

  defp revoke(role, user, actor) do
    {count, _} =
      RoleMembership
      |> where([m], m.role_id == ^role.id and m.user_id == ^user.id)
      |> Repo.delete_all()

    # Leaving isn't a staff action.
    if count > 0 and actor.id != user.id,
      do: StaffLog.record(actor, "role.revoke", user, %{role: role.name, username: user.username})

    {:ok, user}
  end

  @doc "Makes `user` an owner of the group or not, as `admin` (staff-logged)."
  def set_owner(%Role{} = role, %User{} = user, owner?, %User{} = admin) do
    cond do
      Role.automatic?(role) -> {:error, :automatic}
      admin?(admin) -> Repo.transact(fn -> owner(role, user, owner?, admin) end)
      true -> {:error, :unauthorized}
    end
  end

  defp owner(role, user, owner?, admin) do
    query = from(m in RoleMembership, where: m.role_id == ^role.id and m.user_id == ^user.id)

    case Repo.update_all(query, set: [owner: owner?]) do
      {1, _} ->
        action = if owner?, do: "role.owner", else: "role.unowner"
        StaffLog.record(admin, action, user, %{role: role.name, username: user.username})
        {:ok, user}

      _none ->
        {:error, :not_member}
    end
  end

  @doc "Sets how `user` hears about the group's inbox (see `RoleMembership`)."
  def set_notification_level(%Role{} = role, %User{} = user, level) do
    if level in RoleMembership.levels() do
      case Repo.update_all(
             from(m in RoleMembership, where: m.role_id == ^role.id and m.user_id == ^user.id),
             set: [notification_level: level]
           ) do
        {1, _} -> :ok
        _none -> {:error, :not_member}
      end
    else
      {:error, :invalid_level}
    end
  end

  @doc "`user`'s level for the group's inbox, or nil if they're not a member."
  def notification_level(role, user) do
    case membership(role, user) do
      %RoleMembership{notification_level: level} -> level
      nil -> nil
    end
  end

  ## Joining

  @doc """
  `user` joins an `open` group, or asks to join a `request` one (notifying
  its owners, or the admins without owners). Returns `{:ok, :joined}` or
  `{:ok, :requested}`, else `{:error, reason}`.
  """
  def join(%Role{} = role, %User{} = user, message \\ nil) do
    cond do
      Role.staff?(role) or Role.automatic?(role) or not visible?(role, user) ->
        {:error, :closed}

      member?(role, user) ->
        {:error, :already_member}

      role.membership == "open" ->
        join_open(role, user)

      role.membership == "request" ->
        ask(role, user, message)

      true ->
        {:error, :closed}
    end
  end

  defp join_open(role, user) do
    case Groups.add_role(user, role) do
      {:ok, _} -> {:ok, :joined}
      {:error, _} -> {:error, :already_member}
    end
  end

  defp ask(role, user, message) do
    attrs = %{role_id: role.id, user_id: user.id, kind: "request", message: trim(message)}

    case Repo.insert(struct(GroupRequest, attrs), on_conflict: :nothing) do
      {:ok, %GroupRequest{id: nil}} ->
        {:error, :already_requested}

      {:ok, _request} ->
        for manager <- managers(role) do
          Notifications.notify(manager, %{
            kind: "group_request",
            subject: "@#{user.username} asked to join #{role.name}",
            body: trim(message) || "Approve or deny it on the group's page.",
            url: Firefly.URLs.group_url(role, "requests")
          })
        end

        {:ok, :requested}
    end
  end

  defp trim(nil), do: nil

  defp trim(text) do
    case text |> String.trim() |> String.slice(0, 200) do
      "" -> nil
      text -> text
    end
  end

  # Owners decide on requests; without owners, the admins do.
  defp managers(role) do
    owners =
      Repo.all(
        from(u in User,
          join: m in RoleMembership,
          on: m.user_id == u.id and m.role_id == ^role.id and m.owner
        )
      )

    if owners != [], do: owners, else: admins()
  end

  defp admins do
    Repo.all(
      from(u in User,
        join: r in assoc(u, :roles),
        where: r.name == "admin" and is_nil(u.deleted_at)
      )
    )
  end

  @doc "The group's pending requests and invitations, oldest first, with their users."
  def pending(%Role{id: role_id}) do
    Repo.all(
      from(r in GroupRequest,
        where: r.role_id == ^role_id,
        order_by: r.id,
        preload: :user
      )
    )
  end

  @doc "`user`'s pending request or invitation for the group, or nil."
  def pending_for(%Role{id: role_id}, %User{id: user_id}),
    do: Repo.get_by(GroupRequest, role_id: role_id, user_id: user_id)

  def pending_for(_role, nil), do: nil

  @doc """
  Approves (`true`) or denies a request to join, as an owner or admin. The
  requester is told either way.
  """
  def decide(%Role{} = role, request_id, approve?, %User{} = actor) do
    with :ok <- authorize_manager(role, actor),
         %GroupRequest{kind: "request"} = request <-
           Repo.get_by(GroupRequest, id: request_id, role_id: role.id) || {:error, :not_found},
         user = Repo.get!(User, request.user_id),
         {:ok, user} <- if(approve?, do: grant(role, user, actor), else: deny(request, user)) do
      Notifications.notify(user, %{
        kind: "group_request",
        subject:
          if(approve?,
            do: "You joined #{role.name}",
            else: "Your request to join #{role.name} was declined"
          ),
        body: "From @#{actor.username}.",
        url: Firefly.URLs.group_url(role)
      })

      {:ok, user}
    end
  end

  defp deny(request, user), do: with({:ok, _} <- Repo.delete(request), do: {:ok, user})

  @doc "Invites the user named `username` to the group, as an owner or admin."
  def invite(%Role{} = role, username, %User{} = actor) do
    with :ok <- manual(role),
         :ok <- authorize_manager(role, actor),
         {:ok, user} <- find_user(username),
         true <- not member?(role, user) || {:error, :already_member} do
      attrs = %{role_id: role.id, user_id: user.id, kind: "invite"}

      Repo.insert!(struct(GroupRequest, attrs),
        on_conflict: [set: [kind: "invite"]],
        conflict_target: [:role_id, :user_id]
      )

      Notifications.notify(user, %{
        kind: "group_invite",
        subject: "@#{actor.username} invited you to join #{role.name}",
        body: "Accept or decline on the group's page.",
        url: Firefly.URLs.group_url(role)
      })

      {:ok, user}
    end
  end

  @doc "Accepts (`true`) or declines an invitation to the group, as the invitee."
  def answer_invite(%Role{} = role, %User{} = user, accept?) do
    case pending_for(role, user) do
      %GroupRequest{kind: "invite"} = invite ->
        Repo.transact(fn -> answer(invite, role, user, accept?) end)

      _none ->
        {:error, :not_found}
    end
  end

  defp answer(invite, role, user, accept?) do
    Repo.delete!(invite)

    if accept? do
      {:ok, _} = Groups.add_role(user, role)
      {:ok, :joined}
    else
      {:ok, :declined}
    end
  end

  ## Activity

  @doc "The latest posts by the group's members that `viewer` may read, newest first."
  def activity(%Role{id: role_id}, viewer, limit \\ 20) do
    members = from(m in RoleMembership, where: m.role_id == ^role_id, select: m.user_id)

    Post
    |> Post.visible()
    |> where([p], p.user_id in subquery(members) and is_nil(p.hidden_at))
    |> join(:inner, [p], t in assoc(p, :thread), as: :thread)
    |> Firefly.Discussion.Policy.readable_threads(viewer)
    |> order_by([p], desc: p.inserted_at, desc: p.id)
    |> limit(^limit)
    |> preload([p], thread: [:category], user: [])
    |> Repo.all()
  end

  ## Mentions

  @doc """
  Notifies the members of the groups a post newly @mentions (those its
  author may mention; see `can_mention?/2`), as `"group_mentioned"`. The
  caller passes the users already notified of the post (they're skipped)
  and decides who may read the thread (`readers`, a function from users
  to the ids of those who may). Returns the ids notified.
  """
  def notify_mentions(thread, post, author, skip_ids, readers) do
    names = Firefly.Discussion.Mentions.usernames(post.body)
    users = Accounts.users_by_username(names)

    groups =
      names
      |> Enum.reject(&Map.has_key?(users, &1))
      |> by_names()
      |> Map.values()
      |> Enum.filter(&can_mention?(&1, author))

    already =
      Repo.all(
        from(n in Notification,
          where: n.post_id == ^post.id and n.kind in ["mentioned", "group_mentioned"],
          select: n.user_id
        )
      )

    Enum.reduce(groups, [], fn group, notified ->
      skip = skip_ids ++ already ++ notified

      members =
        for m <- memberships(group), m.user.id != author.id, m.user.id not in skip, do: m.user

      allowed = readers.(members)

      notified ++
        for user <- members, MapSet.member?(allowed, user.id) do
          {:ok, _} = Notifications.notify(user, group_mention(thread, post, author, group))
          user.id
        end
    end)
  end

  defp group_mention(thread, post, author, group) do
    %{
      Notification.for_post("mentioned", thread, post, author)
      | kind: "group_mentioned",
        subject: "@#{author.username} mentioned @#{group.name} in \"#{thread.title}\""
    }
  end

  ## Account data

  @doc "The export of `user`'s groups and pending requests (see `Firefly.Accounts.AccountExport`)."
  def export(%User{id: user_id}) do
    memberships =
      Repo.all(
        from(m in RoleMembership,
          join: r in assoc(m, :role),
          where: m.user_id == ^user_id,
          select: %{group: r.name, owner: m.owner, notification_level: m.notification_level}
        )
      )

    pending =
      Repo.all(
        from(g in GroupRequest,
          join: r in assoc(g, :role),
          where: g.user_id == ^user_id,
          select: %{group: r.name, kind: g.kind, inserted_at: g.inserted_at}
        )
      )

    %{memberships: memberships, pending: pending}
  end

  @doc "A message for an error from this module."
  def message(:no_such_user), do: "No user with that username."
  def message(:already_member), do: "They're already in that group."
  def message(:own_admin), do: "You can't remove yourself from the admins."
  def message(:unauthorized), do: "Only the group's owners and admins can do that."
  def message(:closed), do: "This group can't be joined that way."
  def message(:already_requested), do: "You've already asked to join."
  def message(:not_found), do: "That request is gone."
  def message(:not_member), do: "They're not in that group."
  def message(:invalid_level), do: "Pick a notification level."
  def message(:automatic), do: "Trust level groups' members follow their trust level."
  def message(:reserved), do: "The staff and trust level groups can't be renamed or deleted."

  def message(:in_use),
    do: "A category is restricted to this group: change the category's groups first."

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
end
