defmodule Firefly.Accounts.UserAdmin do
  @moduledoc """
  What staff do to accounts from the users admin (`/staff/users`):
  listing and searching them, editing an account's username, name and
  email, approving or rejecting accounts that wait for approval (the
  `must_approve_users` site setting), anonymizing or deleting accounts,
  merging one account into another, sending a password reset, granting and
  revoking the admin and moderator roles, sending a notice, and recording
  impersonation. Who may do which is `Firefly.Discussion.Policy`'s
  business (`:view_users`, `:approve_user`, `:manage_users`,
  `:impersonate`); every change here goes to the staff log in its
  transaction.

  Staff accounts can't be anonymized, deleted, merged or impersonated:
  take their role away first.
  """

  import Ecto.Query

  alias Firefly.{Accounts, Discussion, Groups, Notifications, Repo}
  alias Firefly.Accounts.{AccountDeletion, PasswordReset, User, UserIPs, UserSessions}
  alias Firefly.Discussion.{Post, Thread}
  alias Firefly.Groups.{Role, RoleMembership}
  alias Firefly.Moderation.StaffLog
  alias Firefly.Notifications.Notification

  @filters ~w(all active new staff suspended silenced pending)

  @doc "The list filters: `all`, `active`, `new`, `staff`, `suspended`, `silenced` and `pending`."
  def filters, do: @filters

  @doc """
  A page of accounts (not deleted ones), newest first. `params` (string
  keys): `"filter"` (see `filters/0`; `active` is seen in the last 30
  days, `new` is trust level 0, `pending` waits for approval) and `"q"`,
  matched against username, name and email, or an exact IP address.
  """
  def list(params, page) do
    User
    |> where([u], is_nil(u.deleted_at) and is_nil(u.plugin_bot))
    |> filter(params["filter"])
    |> search(params["q"])
    |> order_by(desc: :id)
    |> Repo.paginate(page: page, page_size: 50)
  end

  defp filter(query, "active") do
    since = DateTime.add(DateTime.utc_now(:second), -30, :day)
    where(query, [u], u.last_seen_at > ^since)
  end

  defp filter(query, "new"), do: where(query, [u], u.trust_level == 0)

  defp filter(query, "staff") do
    staff =
      from(m in RoleMembership,
        join: r in Role,
        on: r.id == m.role_id and r.name in ["admin", "moderator"],
        select: m.user_id
      )

    where(query, [u], u.id in subquery(staff))
  end

  defp filter(query, "suspended"), do: where(query, [u], u.suspended_until > ^DateTime.utc_now())
  defp filter(query, "silenced"), do: where(query, [u], u.silenced_until > ^DateTime.utc_now())
  defp filter(query, "pending"), do: where(query, [u], not u.approved)
  defp filter(query, _all), do: query

  defp search(query, q) when is_binary(q) and q != "" do
    q = String.trim(q)

    case Firefly.IPRange.address(q) do
      nil ->
        pattern = "%" <> String.replace(q, ~r/[\\%_]/, "\\\\\\0") <> "%"

        where(
          query,
          [u],
          ilike(u.username, ^pattern) or ilike(u.name, ^pattern) or ilike(u.email, ^pattern)
        )

      _ip ->
        where(query, [u], u.id in subquery(UserIPs.user_ids_at(q)))
    end
  end

  defp search(query, _blank), do: query

  @doc "How many accounts wait for approval."
  def pending_count,
    do: Repo.aggregate(from(u in User, where: not u.approved and is_nil(u.deleted_at)), :count)

  @doc "`user`'s groups (roles), by name."
  def groups(%User{} = user),
    do: user |> Repo.preload(:roles, force: true) |> Map.fetch!(:roles) |> Enum.sort_by(& &1.name)

  @doc "How many threads and posts (deleted ones too) `user` wrote."
  def content_counts(%User{id: id} = user) do
    %{
      posts: Repo.aggregate(from(p in Post, where: p.user_id == ^id), :count),
      threads: Repo.aggregate(started_threads(user), :count)
    }
  end

  ## Editing

  @doc "A changeset of the fields staff edit (username, name, email)."
  def change(%User{} = user, attrs \\ %{}) do
    user
    |> User.changeset(attrs)
    |> Ecto.Changeset.validate_format(:username, ~r/^[A-Za-z0-9_-]+$/,
      message: "can only contain letters, numbers, - and _"
    )
    |> Ecto.Changeset.validate_length(:username, min: 2, max: 32)
    |> Ecto.Changeset.validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
      message: "must be a valid email"
    )
    |> Ecto.Changeset.validate_length(:email, max: 160)
  end

  @doc """
  Changes `user`'s username, name or email as `admin` (staff-logged as
  `user.edit` with the before and after values). An email staff set
  stays confirmed as it was: staff vouch for it.
  """
  def update(%User{} = user, attrs, %User{} = admin) do
    changeset = change(user, attrs)

    Repo.transact(fn ->
      with {:ok, updated} <- Repo.update(changeset),
           do: {:ok, log_edit(updated, StaffLog.changes(changeset), admin)}
    end)
  end

  defp log_edit(user, details, _admin) when details == %{}, do: user

  defp log_edit(user, details, admin) do
    StaffLog.record(admin, "user.edit", user, details)
    user
  end

  ## Approval

  @doc "Approves `user`'s account as `staff`: they can post. They're told in a notification."
  def approve(%User{approved: false} = user, %User{} = staff) do
    result =
      Repo.transact(fn ->
        {:ok, approved} =
          user
          |> Ecto.Changeset.change(
            approved: true,
            approved_at: DateTime.utc_now(:second),
            approved_by_id: staff.id
          )
          |> Repo.update()

        StaffLog.record(staff, "user.approve", approved, %{username: approved.username})
        {:ok, approved}
      end)

    with {:ok, approved} <- result do
      Notifications.notify(approved, %{
        kind: "approved",
        subject: "Your account was approved",
        body: "You can post now. Welcome!",
        url: Firefly.URLs.user_url(approved)
      })

      UserSessions.reload_pages(approved)
      {:ok, approved}
    end
  end

  def approve(%User{}, _staff), do: {:error, :not_pending}

  @doc "Rejects an account that waits for approval, as `staff`: it's deleted (anonymized)."
  def reject(%User{approved: false} = user, %User{} = staff),
    do: remove(user, staff, "user.reject", %{username: user.username})

  def reject(%User{}, _staff), do: {:error, :not_pending}

  ## Removing

  @doc """
  Anonymizes `user`'s account as `admin` (see
  `Firefly.Accounts.AccountDeletion`): their posts stay, under a
  placeholder. Staff accounts can't be (`{:error, :staff}`).
  """
  def anonymize(%User{} = user, %User{} = admin), do: remove(user, admin, "user.anonymize", %{})

  @doc """
  Deletes `user` and what they wrote, as `admin`: the threads they started
  (with their replies), their other posts (soft-deleted, as staff delete
  posts), then the account is anonymized. Each thread and post deletion is
  staff-logged as usual, and the whole as `user.delete` with the counts.
  """
  def delete(%User{} = user, %User{} = admin) do
    with :ok <- removable(user),
         {:ok, {deleted, announces}} <- Repo.transact(fn -> delete_all(user, admin) end) do
      Enum.each(announces, & &1.())
      {:ok, deleted}
    end
  end

  # In the transaction: `{:ok, {deleted, announces}}`, the announcements
  # to make once it commits.
  defp delete_all(user, admin) do
    threads = Repo.all(started_threads(user))
    thread_announces = Enum.map(threads, &delete_thread(&1, admin))
    post_announces = delete_posts(user, admin)
    details = %{threads: length(threads), posts: length(post_announces)}

    with {:ok, deleted} <- anonymize_logged(user, admin, "user.delete", details),
         do: {:ok, {deleted, thread_announces ++ post_announces}}
  end

  defp delete_thread(thread, admin) do
    {:ok, _deleted, announce} = Discussion.delete_thread_unannounced(thread, admin)
    announce
  end

  # Their replies (first posts went with their threads).
  defp delete_posts(user, admin) do
    for post <- Repo.all(from(p in Post, where: p.user_id == ^user.id and is_nil(p.deleted_at))),
        not Discussion.first_post?(post) do
      {:ok, _deleted, announce} = Discussion.delete_post_unannounced(post, admin)
      announce
    end
  end

  defp started_threads(%User{id: id}) do
    first_posts =
      from(p in Post, group_by: p.thread_id, select: %{thread_id: p.thread_id, id: min(p.id)})

    from(t in Thread,
      join: f in subquery(first_posts),
      on: f.thread_id == t.id,
      join: p in Post,
      on: p.id == f.id and p.user_id == ^id
    )
  end

  defp remove(user, actor, action, details) do
    with :ok <- removable(user),
         do: Repo.transact(fn -> anonymize_logged(user, actor, action, details) end)
  end

  # Logged after anonymizing, which scrubs who the account was from the
  # log: `details` hold only what's safe to keep.
  defp anonymize_logged(user, actor, action, details) do
    with {:ok, deleted} <- AccountDeletion.anonymize(user) do
      StaffLog.record(actor, action, deleted, details)
      {:ok, deleted}
    end
  end

  defp removable(user) do
    cond do
      User.deleted?(user) -> {:error, :deleted}
      Accounts.staff?(user) -> {:error, :staff}
      true -> :ok
    end
  end

  ## Merging

  @doc """
  Merges `source` into `target` as `admin`: everything `source` owns
  (posts, threads, messages, likes, bookmarks, groups, badges, uploads,
  notifications, read positions, settings rows...) moves to `target`, and
  `source` is removed. Where both have the same thing (a like of the same
  post, the same group), `target`'s is kept. Staff and deleted accounts
  can't be merged. Staff-logged as `user.merge` on `target`.
  """
  def merge(%User{id: id}, %User{id: id}, _admin), do: {:error, :same_user}

  def merge(%User{} = source, %User{} = target, %User{} = admin) do
    with :ok <- removable(source),
         :ok <- if(User.deleted?(target), do: {:error, :deleted}, else: :ok) do
      {:ok, target} =
        Repo.transact(fn ->
          moved = Enum.sum_by(user_columns(), &move_rows(&1, source.id, target.id))
          Repo.delete!(source)

          StaffLog.record(admin, "user.merge", target, %{
            from: source.username,
            to: target.username,
            rows: moved
          })

          {:ok, target}
        end)

      # The merged account's open pages come back logged out.
      UserSessions.reload_pages(source)
      {:ok, target}
    end
  end

  # Every column that holds a user's id: the foreign keys to forums_users,
  # and `user_id` columns that have none (counters and logs).
  defp user_columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT cl.relname, att.attname
        FROM pg_constraint con
        JOIN pg_class cl ON cl.oid = con.conrelid
        JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = con.conkey[1]
       WHERE con.contype = 'f' AND con.confrelid = 'forums_users'::regclass
         AND array_length(con.conkey, 1) = 1
      UNION
      SELECT c.table_name, c.column_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_schema = c.table_schema AND t.table_name = c.table_name
       WHERE c.table_schema = current_schema() AND t.table_type = 'BASE TABLE'
         AND c.column_name = 'user_id' AND c.data_type IN ('bigint', 'integer')
      ORDER BY 1, 2
      """)

    Enum.map(rows, fn [table, column] -> {table, column} end)
  end

  # Drops `from`'s rows that would collide with `to`'s under a unique index
  # on `column`, then moves the rest.
  defp move_rows({table, column}, from, to) do
    for other_columns <- unique_index_columns(table, column) do
      same =
        Enum.map_join(
          other_columns,
          "",
          &" AND o.#{quote_name(&1)} IS NOT DISTINCT FROM s.#{quote_name(&1)}"
        )

      Repo.query!(
        "DELETE FROM #{quote_name(table)} s WHERE s.#{quote_name(column)} = $1 AND EXISTS " <>
          "(SELECT 1 FROM #{quote_name(table)} o WHERE o.#{quote_name(column)} = $2#{same})",
        [from, to]
      )
    end

    %{num_rows: count} =
      Repo.query!(
        "UPDATE #{quote_name(table)} SET #{quote_name(column)} = $2 WHERE #{quote_name(column)} = $1",
        [from, to]
      )

    count
  end

  # The other columns of each unique index (or primary key) that includes
  # `column`, leaving out expression indexes' expressions.
  defp unique_index_columns(table, column) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT array_agg(a.attname ORDER BY a.attname) FILTER (WHERE a.attname <> $2)
          FROM pg_index i
          JOIN pg_class t ON t.oid = i.indrelid
          JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(i.indkey)
         WHERE t.relname = $1 AND i.indisunique
         GROUP BY i.indexrelid
        HAVING bool_or(a.attname = $2)
        """,
        [table, column]
      )

    Enum.map(rows, fn [columns] -> columns || [] end)
  end

  defp quote_name(name), do: ~s("#{String.replace(name, ~s("), ~s(""))}")

  ## Roles

  @doc """
  Grants (`grant?` true) or revokes the `"admin"` or `"moderator"` role of
  `user`, as `admin` (staff-logged as `role.grant`/`role.revoke`; see
  `Firefly.Groups`). Admins can't take their own admin role.
  """
  def set_staff_role(%User{} = user, role, grant?, %User{} = admin)
      when role in ~w(admin moderator) do
    group = Groups.staff_group(role)

    if grant?,
      do: Groups.add_member(group, user.username, admin),
      else: Groups.remove_member(group, user, admin)
  end

  ## Password reset and notices

  @doc "Emails `user` a password reset link as `admin` (staff-logged)."
  def send_password_reset(%User{} = user, %User{} = admin) do
    with :ok <- PasswordReset.deliver(user) do
      StaffLog.record(admin, "user.password_reset", user, %{username: user.username})
      :ok
    end
  end

  @doc """
  Sends `user` a notice from staff (`"subject"`, optional `"body"` and
  `"url"`: their notifications page by default), as `admin`
  (staff-logged).
  """
  def send_notification(%User{} = user, params, %User{} = admin) do
    subject = String.trim(params["subject"] || "")

    attrs = %{
      kind: "staff",
      subject: subject,
      body: blank_to_nil(params["body"]) || subject,
      url: blank_to_nil(params["url"]) || Firefly.URLs.notifications_url()
    }

    changeset = Notification.changeset(%Notification{}, Map.put(attrs, :user_id, user.id))

    cond do
      attrs.subject == "" ->
        {:error, :blank_subject}

      not changeset.valid? ->
        {:error, :invalid}

      true ->
        {:ok, notification} = Notifications.notify(user, attrs)

        StaffLog.record(admin, "notification.send", user, %{
          username: user.username,
          subject: notification.subject
        })

        {:ok, notification}
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    case String.trim(text) do
      "" -> nil
      text -> text
    end
  end

  @doc """
  `user`'s latest notifications for staff to look over: kind, subject and
  when. Private conversations' notifications are left out (staff don't
  read others' messages).
  """
  def notifications(%User{id: id}, limit \\ 20) do
    Repo.all(
      from(n in Notification,
        where: n.user_id == ^id and is_nil(n.conversation_id) and n.kind != "chat_message",
        order_by: [desc: n.id],
        limit: ^limit
      )
    )
  end

  @doc "Deletes one of `user`'s notifications as `admin` (staff-logged)."
  def delete_notification(%User{} = user, notification_id, %User{} = admin) do
    query =
      from(n in Notification,
        where: n.id == ^notification_id and n.user_id == ^user.id and is_nil(n.conversation_id)
      )

    result =
      Repo.transact(fn ->
        case Repo.one(query) do
          nil ->
            {:error, :not_found}

          notification ->
            Repo.delete!(notification)

            StaffLog.record(admin, "notification.delete", user, %{
              username: user.username,
              subject: notification.subject
            })

            {:ok, notification}
        end
      end)

    if match?({:ok, _}, result), do: Notifications.notifications_changed(user.id)
    result
  end

  ## Impersonation

  @doc "Records that `admin` started seeing the site as `user` (see `FireflyWeb.StaffController`)."
  def impersonated(%User{} = admin, %User{} = user),
    do: StaffLog.record(admin, "user.impersonate", user, %{username: user.username})

  @doc "Records that `admin` stopped impersonating `user`."
  def stopped_impersonating(%User{} = admin, %User{} = user),
    do: StaffLog.record(admin, "user.impersonate_stop", user, %{username: user.username})

  @doc "A message for an error from this module."
  def message(:staff), do: "Staff accounts can't be changed that way: take their role away first."
  def message(:deleted), do: "That account is deleted."
  def message(:not_pending), do: "That account isn't waiting for approval."
  def message(:same_user), do: "Pick another account to merge into."
  def message(:last_admin), do: "That's the only admin."
  def message(:no_email), do: "That account has no email address."
  def message(:blank_subject), do: "Give the notice a subject."
  def message(:invalid), do: "That notice isn't valid."
  def message(:not_found), do: "That's gone already."

  def message(reason) when reason in [:no_such_user, :already_member, :own_admin, :not_member],
    do: Groups.message(reason)

  def message(_error), do: "That didn't work. Please try again."
end
