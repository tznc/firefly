defmodule Firefly.Badges do
  @moduledoc """
  Badges, as Discourse's: members earn system badges for what they do,
  and admins create custom badges and grant them by hand.

  System badges (`system_badges/0`) are defined here, each by a query of
  who earned it (and with which post, and when). `run_due/0` (run by
  `Firefly.Jobs.Periodic`, every 15 minutes across nodes) creates any
  missing system badge and grants each enabled one to everyone its query finds; a trust level change grants
  the trust level badges at once (`grant_earned/1` for that member). A
  badge is granted once, or with `multiple_grant` once per post (Nice
  Reply and the like). Each grant notifies the member (`"badge_granted"`).
  Grants of a badge are serialized with an advisory lock, so the job and
  admins never grant one twice.

  Admins (the `:manage_badges` policy) create, edit and delete custom
  badges, switch system badges on or off, and grant and revoke badges,
  staff-logged. A disabled badge isn't granted or shown. Members show a
  badge that allows it as their title (`set_title/2`).

  Badge pages list who holds a badge, linking a grant's post only for
  viewers who may read it.
  """

  use Boundary, top_level?: true, check: [out: false], exports: [Badge]

  import Ecto.Query

  alias Firefly.{Notifications, Repo}
  alias Firefly.Moderation.StaffLog
  alias Firefly.Accounts.User
  alias Firefly.Badges.{Badge, UserBadge}
  alias Firefly.Discussion.{Policy, Post}

  # The published posts of a query's `p`.
  @published "p.deleted_at IS NULL AND p.queued_at IS NULL AND p.hidden_at IS NULL"

  # Posts that start their thread.
  @first_posts "SELECT DISTINCT ON (thread_id) id FROM forums_posts ORDER BY thread_id, inserted_at, id"

  @doc """
  The system badges: their fields and `query`, SQL selecting `user_id`,
  `post_id` (or NULL) and `granted_at` for the users who earned them,
  limited to the user ids in `$1` when it isn't NULL.
  """
  def system_badges do
    trust_level_badges() ++
      [
        %{
          name: "Welcome",
          description: "Received a like.",
          icon: "hero-hand-raised",
          badge_type: "bronze",
          grouping: "getting_started",
          query: """
          SELECT DISTINCT ON (p.user_id) p.user_id, p.id, l.inserted_at
          FROM forums_post_likes l JOIN forums_posts p ON p.id = l.post_id
          WHERE #{@published} AND ($1::bigint[] IS NULL OR p.user_id = ANY($1))
          ORDER BY p.user_id, l.inserted_at
          """
        },
        %{
          name: "First Like",
          description: "Liked a post.",
          icon: "hero-heart",
          badge_type: "bronze",
          grouping: "getting_started",
          query: """
          SELECT DISTINCT ON (l.user_id) l.user_id, l.post_id, l.inserted_at
          FROM forums_post_likes l
          WHERE $1::bigint[] IS NULL OR l.user_id = ANY($1)
          ORDER BY l.user_id, l.inserted_at
          """
        },
        first_post_matching(
          "First Quote",
          "Quoted a post.",
          "hero-chat-bubble-left-right",
          "\\[@[A-Za-z0-9_-]+ said:\\]\\("
        ),
        %{
          name: "First Mention",
          description: "Mentioned a member in a post.",
          icon: "hero-at-symbol",
          badge_type: "bronze",
          grouping: "getting_started",
          query: """
          SELECT DISTINCT ON (p.user_id) p.user_id, p.id, p.inserted_at
          FROM forums_posts p
          CROSS JOIN LATERAL regexp_matches(p.body, '(?:^|[^\\w@#/&])@([A-Za-z0-9_-]+)', 'g') AS m
          JOIN forums_users u ON lower(u.username) = lower(m[1]) AND u.id <> p.user_id
          WHERE #{@published} AND ($1::bigint[] IS NULL OR p.user_id = ANY($1))
          ORDER BY p.user_id, p.inserted_at
          """
        },
        first_post_matching(
          "First Link",
          "Linked to another thread.",
          "hero-link",
          "/categories/[0-9]+/threads/[0-9]+"
        ),
        %{
          name: "Editor",
          description: "Edited one of their posts.",
          icon: "hero-pencil",
          badge_type: "bronze",
          grouping: "getting_started",
          query: """
          SELECT DISTINCT ON (r.user_id) r.user_id, r.post_id, r.inserted_at
          FROM forums_post_revisions r JOIN forums_posts p ON p.id = r.post_id
          WHERE p.user_id = r.user_id AND ($1::bigint[] IS NULL OR r.user_id = ANY($1))
          ORDER BY r.user_id, r.inserted_at
          """
        },
        %{
          name: "Autobiographer",
          description: "Filled in their profile: an About me and a profile picture.",
          icon: "hero-identification",
          badge_type: "bronze",
          grouping: "getting_started",
          query: """
          SELECT id, NULL::bigint, now() FROM forums_users
          WHERE deleted_at IS NULL AND coalesce(trim(bio), '') <> '' AND avatar_upload_id IS NOT NULL
            AND ($1::bigint[] IS NULL OR id = ANY($1))
          """
        },
        %{
          name: "Solved",
          description: "Had a reply accepted as a thread's answer.",
          icon: "hero-check-circle",
          badge_type: "bronze",
          grouping: "community",
          query: """
          SELECT DISTINCT ON (p.user_id) p.user_id, p.id, t.updated_at
          FROM forums_threads t JOIN forums_posts p ON p.id = t.accepted_post_id
          WHERE #{@published} AND ($1::bigint[] IS NULL OR p.user_id = ANY($1))
          ORDER BY p.user_id, t.updated_at
          """
        }
      ] ++ liked_post_badges()
  end

  defp trust_level_badges do
    for {name, level, type, title?} <- [
          {"Basic User", 1, "bronze", false},
          {"Member", 2, "bronze", false},
          {"Regular", 3, "silver", true},
          {"Leader", 4, "gold", true}
        ] do
      %{
        name: name,
        description: "Reached trust level #{level}.",
        icon: "hero-shield-check",
        badge_type: type,
        grouping: "trust_level",
        allow_title: title?,
        query: """
        SELECT id, NULL::bigint, coalesce(trust_level_changed_at, now()) FROM forums_users
        WHERE deleted_at IS NULL AND trust_level >= #{level}
          AND ($1::bigint[] IS NULL OR id = ANY($1))
        """
      }
    end
  end

  defp first_post_matching(name, description, icon, pattern) do
    %{
      name: name,
      description: description,
      icon: icon,
      badge_type: "bronze",
      grouping: "getting_started",
      query: """
      SELECT DISTINCT ON (p.user_id) p.user_id, p.id, p.inserted_at FROM forums_posts p
      WHERE #{@published} AND p.body ~ '#{pattern}'
        AND ($1::bigint[] IS NULL OR p.user_id = ANY($1))
      ORDER BY p.user_id, p.inserted_at
      """
    }
  end

  # Nice, Good and Great Reply and Topic: once per post with that many likes.
  defp liked_post_badges do
    for {grade, likes, type} <- [
          {"Nice", 10, "bronze"},
          {"Good", 25, "silver"},
          {"Great", 50, "gold"}
        ],
        {kind, first?} <- [{"Reply", false}, {"Topic", true}] do
      %{
        name: "#{grade} #{kind}",
        description:
          "#{if first?, do: "Started a thread", else: "Replied"} with a post liked #{likes} times.",
        icon: "hero-fire",
        badge_type: type,
        grouping: "posting",
        multiple_grant: true,
        query: """
        SELECT p.user_id, p.id, max(l.inserted_at)
        FROM forums_posts p JOIN forums_post_likes l ON l.post_id = p.id
        WHERE #{@published} AND p.id #{if first?, do: "IN", else: "NOT IN"} (#{@first_posts})
          AND ($1::bigint[] IS NULL OR p.user_id = ANY($1))
        GROUP BY p.user_id, p.id HAVING count(*) >= #{likes}
        """
      }
    end
  end

  ## Granting

  @doc "Grants what's earned (every 15 minutes across nodes, see `Firefly.Jobs.Periodic`)."
  def run_due, do: grant_earned(nil)

  @doc """
  Creates any missing system badge, then grants each enabled one to whoever
  earned it: everyone, or the users with ids in `user_ids`.
  """
  def grant_earned(user_ids) do
    ensure_system_badges()
    queries = Map.new(system_badges(), &{&1.name, &1.query})

    granted =
      Badge
      |> where([b], b.system and b.enabled)
      |> Repo.all()
      |> Enum.filter(&Map.has_key?(queries, &1.name))
      |> Enum.flat_map(&grant_query(&1, queries[&1.name], user_ids))

    Enum.each(granted, &notify/1)
  end

  defp ensure_system_badges do
    now = DateTime.utc_now(:second)

    rows =
      for definition <- system_badges() do
        definition
        |> Map.delete(:query)
        |> Map.merge(%{system: true, inserted_at: now, updated_at: now})
      end

    Repo.insert_all(Badge, rows, on_conflict: :nothing)
  end

  defp grant_query(badge, query, user_ids) do
    # A single badge goes to users who don't hold it; a multiple one, for
    # posts it wasn't granted for (the unique index).
    held =
      if badge.multiple_grant,
        do: "",
        else:
          "AND NOT EXISTS (SELECT 1 FROM user_badges h WHERE h.badge_id = $2 AND h.user_id = e.user_id)"

    {:ok, rows} =
      Repo.transact(fn ->
        lock(badge)

        %{rows: rows} =
          Repo.query!(
            """
            WITH earned (user_id, post_id, granted_at) AS (#{query})
            INSERT INTO user_badges (badge_id, user_id, post_id, granted_at)
            SELECT $2, e.user_id, e.post_id, date_trunc('second', e.granted_at)
            FROM earned e JOIN forums_users u ON u.id = e.user_id
            WHERE u.deleted_at IS NULL #{held}
            ON CONFLICT DO NOTHING
            RETURNING id
            """,
            [user_ids, badge.id]
          )

        {:ok, rows}
      end)

    Enum.map(rows, fn [id] -> id end)
  end

  defp lock(%Badge{id: id}),
    do: Repo.query!("SELECT pg_advisory_xact_lock(hashtext('badges'), $1::int)", [id])

  defp notify(user_badge_id) do
    %UserBadge{badge: badge, user: user} =
      UserBadge |> Repo.get!(user_badge_id) |> Repo.preload([:badge, :user])

    {:ok, _} =
      Notifications.notify(user, %{
        kind: "badge_granted",
        subject: "You earned the \"#{badge.name}\" badge",
        body: if(badge.description == "", do: "See who else has it.", else: badge.description),
        url: Firefly.URLs.badge_url(badge)
      })
  end

  @doc """
  Grants `badge` to `user` as `admin`, with an optional `reason`
  (staff-logged). Errors: `:disabled`, `:already_granted` (a badge granted
  once, or a multiple one already granted by hand: those are once per post).
  """
  def grant(%Badge{} = badge, %User{} = user, %User{} = admin, reason \\ nil) do
    result =
      Repo.transact(fn ->
        lock(badge)

        cond do
          not badge.enabled ->
            {:error, :disabled}

          granted_by_hand?(badge, user) ->
            {:error, :already_granted}

          true ->
            user_badge =
              Repo.insert!(%UserBadge{
                badge_id: badge.id,
                user_id: user.id,
                granted_by_id: admin.id,
                reason: blank_to_nil(reason),
                granted_at: DateTime.utc_now(:second)
              })

            StaffLog.record(admin, "badge.grant", user, %{
              badge: badge.name,
              username: user.username
            })

            {:ok, user_badge}
        end
      end)

    with {:ok, user_badge} <- result do
      notify(user_badge.id)
      {:ok, user_badge}
    end
  end

  # A badge granted once: whether `user` holds it. A multiple one is
  # granted once per post (the unique index), so by hand, with no post,
  # only once too.
  defp granted_by_hand?(%Badge{multiple_grant: false} = badge, user), do: holds?(user, badge)

  defp granted_by_hand?(%Badge{id: badge_id}, %User{id: user_id}),
    do:
      Repo.exists?(
        from(ub in UserBadge,
          where: ub.user_id == ^user_id and ub.badge_id == ^badge_id and is_nil(ub.post_id)
        )
      )

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      text -> String.slice(text, 0, 500)
    end
  end

  @doc """
  Revokes a grant (a `UserBadge` id) as `admin` (staff-logged). A member
  who no longer holds their title badge loses the title.
  """
  def revoke(user_badge_id, %User{} = admin) do
    Repo.transact(fn ->
      case UserBadge |> Repo.get(user_badge_id) |> Repo.preload([:badge, :user]) do
        nil -> {:error, :not_found}
        user_badge -> {:ok, revoke_grant(user_badge, admin)}
      end
    end)
  end

  defp revoke_grant(%UserBadge{badge: badge, user: user} = user_badge, admin) do
    Repo.delete!(user_badge)

    if not holds?(user, badge) do
      User
      |> where([u], u.id == ^user.id and u.title_badge_id == ^badge.id)
      |> Repo.update_all(set: [title_badge_id: nil])
    end

    StaffLog.record(admin, "badge.revoke", user, %{badge: badge.name, username: user.username})
    user_badge
  end

  @doc "Whether `user` holds `badge`."
  def holds?(%User{id: user_id}, %Badge{id: badge_id}),
    do:
      Repo.exists?(
        from(ub in UserBadge, where: ub.user_id == ^user_id and ub.badge_id == ^badge_id)
      )

  ## Admins

  @doc "Every badge, by grouping then name (staff)."
  def list_badges, do: Badge |> order_by([:grouping, :name]) |> Repo.all()

  def change_badge(%Badge{} = badge, attrs \\ %{}), do: Badge.changeset(badge, attrs)

  @doc "Creates a custom badge as `admin` (staff-logged)."
  def create_badge(attrs, %User{} = admin) do
    Repo.transact(fn ->
      with {:ok, badge} <- %Badge{} |> Badge.changeset(attrs) |> Repo.insert() do
        StaffLog.record(admin, "badge.create", {"badge", badge.id}, %{badge: badge.name})
        {:ok, badge}
      end
    end)
  end

  @doc """
  Updates a badge as `admin` (staff-logged): every field of a custom one,
  only `enabled`, `allow_title` and `listable` of a system one.
  """
  def update_badge(%Badge{} = badge, attrs, %User{} = admin) do
    changeset =
      if badge.system,
        do: Badge.system_changeset(badge, attrs),
        else: Badge.changeset(badge, attrs)

    Repo.transact(fn ->
      with {:ok, updated} <- Repo.update(changeset) do
        StaffLog.record(admin, "badge.update", {"badge", badge.id}, %{
          badge: updated.name,
          changes: Map.keys(changeset.changes)
        })

        {:ok, updated}
      end
    end)
  end

  @doc "Deletes a custom badge and its grants as `admin` (staff-logged)."
  def delete_badge(%Badge{system: true}, _admin), do: {:error, :system}

  def delete_badge(%Badge{} = badge, %User{} = admin) do
    Repo.transact(fn ->
      Repo.delete!(badge)
      StaffLog.record(admin, "badge.delete", {"badge", badge.id}, %{badge: badge.name})
      {:ok, badge}
    end)
  end

  ## Reading

  @doc "Gets an enabled badge by id, or raises `Ecto.NoResultsError`."
  def get_enabled!(id), do: Repo.get_by!(Badge, id: id, enabled: true)

  @doc "Gets any badge by id (staff), or raises `Ecto.NoResultsError`."
  def get_badge!(id), do: Repo.get!(Badge, id)

  @doc """
  The enabled, listable badges, with how many members hold each
  (`grant_count`), as `{grouping, badges}` in display order.
  """
  def listing do
    counts =
      from(ub in UserBadge,
        group_by: ub.badge_id,
        select: %{badge_id: ub.badge_id, n: count(ub.user_id, :distinct)}
      )

    badges =
      Badge
      |> where([b], b.enabled and b.listable)
      |> join(:left, [b], c in subquery(counts), on: c.badge_id == b.id)
      |> select([b, c], %{b | grant_count: coalesce(c.n, 0)})
      |> order_by([b], asc: b.name)
      |> Repo.all()
      |> Enum.group_by(& &1.grouping)

    for grouping <- Badge.groupings(), badges[grouping], do: {grouping, badges[grouping]}
  end

  @doc "The ids of the badges `user` (nil: nobody) holds."
  def held_ids(nil), do: MapSet.new()

  def held_ids(%User{id: user_id}),
    do:
      MapSet.new(
        Repo.all(
          from(ub in UserBadge,
            where: ub.user_id == ^user_id,
            distinct: true,
            select: ub.badge_id
          )
        )
      )

  @doc """
  A page of the badge's grants, newest first, with their users, and their
  posts when `viewer` may read them (nil otherwise).
  """
  def grantees(%Badge{id: badge_id}, viewer, page) do
    readable =
      Post
      |> join(:inner, [p], t in assoc(p, :thread), as: :thread)
      |> Policy.readable_threads(viewer)
      |> where([p], is_nil(p.deleted_at) and is_nil(p.hidden_at) and is_nil(p.queued_at))
      |> select([p], p.id)

    result =
      UserBadge
      |> where([ub], ub.badge_id == ^badge_id)
      |> join(:inner, [ub], u in assoc(ub, :user), on: is_nil(u.deleted_at))
      |> order_by([ub], desc: ub.granted_at, desc: ub.id)
      |> preload([ub, u], user: u)
      |> Repo.paginate(page: page, page_size: 30)

    post_ids = for ub <- result.entries, ub.post_id, do: ub.post_id
    ids = MapSet.new(Repo.all(where(readable, [p], p.id in ^post_ids)))

    entries =
      Enum.map(result.entries, fn ub ->
        if MapSet.member?(ids, ub.post_id),
          do: Repo.preload(ub, post: :thread),
          else: %{ub | post: nil}
      end)

    %{result | entries: entries}
  end

  @doc """
  The enabled badges `user` holds, best and newest first, each as
  `{badge, count, last granted_at}`.
  """
  def user_badges(%User{id: user_id}) do
    Badge
    |> join(:inner, [b], ub in UserBadge, on: ub.badge_id == b.id and ub.user_id == ^user_id)
    |> where([b], b.enabled)
    |> group_by([b], b.id)
    |> select([b, ub], {b, count(ub.id), max(ub.granted_at)})
    |> Repo.all()
    |> Enum.sort_by(fn {b, _count, at} -> {type_rank(b.badge_type), -DateTime.to_unix(at)} end)
  end

  defp type_rank("gold"), do: 0
  defp type_rank("silver"), do: 1
  defp type_rank(_bronze), do: 2

  @doc "The badges `user` may show as their title."
  def titles(%User{} = user) do
    for {badge, _count, _at} <- user_badges(user), badge.allow_title, do: badge
  end

  @doc """
  Shows the badge with id `badge_id` as `user`'s title (it must be one of
  `titles/1`), or none (nil or "").
  """
  def set_title(%User{} = user, badge_id) when badge_id in [nil, ""],
    do: user |> Ecto.Changeset.change(title_badge_id: nil) |> Repo.update()

  def set_title(%User{} = user, badge_id) do
    if Enum.any?(titles(user), &(to_string(&1.id) == to_string(badge_id))),
      do:
        user
        |> Ecto.Changeset.change(title_badge_id: String.to_integer(to_string(badge_id)))
        |> Repo.update(),
      else: {:error, :not_allowed}
  end

  @doc "`user`'s title, a badge name, or nil (none, or the badge no longer allows it)."
  def title(%User{title_badge_id: nil}), do: nil

  def title(%User{title_badge_id: id}) do
    Repo.one(from(b in Badge, where: b.id == ^id and b.enabled and b.allow_title, select: b.name))
  end

  ## Account data

  @doc "The export of `user`'s badges (see `Firefly.Accounts.AccountExport`)."
  def export(%User{id: user_id}) do
    Repo.all(
      from(ub in UserBadge,
        join: b in assoc(ub, :badge),
        where: ub.user_id == ^user_id,
        order_by: ub.granted_at,
        select: %{
          badge: b.name,
          granted_at: ub.granted_at,
          post_id: ub.post_id,
          reason: ub.reason
        }
      )
    )
  end

  @doc "A message for an error from this module."
  def message(:disabled), do: "That badge is disabled."
  def message(:already_granted), do: "They already have that badge."
  def message(:not_found), do: "That badge grant is gone."
  def message(:system), do: "System badges can't be deleted; disable them instead."
  def message(:not_allowed), do: "You can't use that badge as a title."
end
