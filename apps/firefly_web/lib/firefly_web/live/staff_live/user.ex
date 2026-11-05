defmodule FireflyWeb.StaffLive.User do
  @moduledoc """
  One account in the users admin (staff only; see
  `Firefly.Accounts.UserAdmin`): its email and logins, trust level,
  groups and staff roles, penalties, the addresses it used (and other
  accounts seen there), its API keys and notifications, and what staff
  can do to it: edit, approve or reject, silence or suspend, reset
  two-factor, send a password reset or a notice, impersonate, anonymize,
  delete with its posts, or merge it into another account. Each action
  checks its own permission (moderators get approval and penalties;
  admins the rest), and every change is staff-logged.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Accounts, Groups, TrustLevels}
  alias Firefly.Accounts.{ApiKeys, Auth, TwoFactor, User, UserAdmin, UserIPs}
  alias Firefly.Groups.Role
  alias Firefly.Moderation.Penalties

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    staff = socket.assigns.current_user

    with true <- can?(staff, :view_users),
         %User{deleted_at: nil} = user <- Accounts.get_user(id) do
      {:ok, socket |> assign(:page_title, user.username) |> load(user)}
    else
      false ->
        {:ok, socket |> put_flash(:error, denied_message(staff)) |> push_navigate(to: ~p"/")}

      _gone ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That account doesn't exist."))
         |> push_navigate(to: ~p"/staff/users")}
    end
  end

  defp load(socket, user) do
    socket
    |> assign(:user, user)
    |> assign_groups(UserAdmin.groups(user))
    |> assign(:identities, user |> Auth.identities() |> Map.values())
    |> assign(:ips, UserIPs.for_user(user))
    |> assign(:sharing, UserIPs.sharing(user))
    |> assign(:api_keys, ApiKeys.list(user))
    |> assign(:notifications, UserAdmin.notifications(user))
    |> assign(:counts, UserAdmin.content_counts(user))
    |> assign(:two_factor?, TwoFactor.enabled?(user))
    |> assign(:account_form, to_form(UserAdmin.change(user)))
    |> assign(:trust_form, trust_form(user))
    |> assign(:penalty_form, penalty_form())
    |> assign(:notice_form, to_form(%{"subject" => "", "body" => "", "url" => ""}, as: :notice))
  end

  defp assign_groups(socket, groups) do
    socket
    |> assign(:groups, groups)
    |> assign(:roles, Enum.map(groups, & &1.name))
  end

  defp reload(socket), do: load(socket, Accounts.get_user!(socket.assigns.user.id))

  defp trust_form(user),
    do:
      to_form(
        %{
          "level" => to_string(user.trust_level),
          "locked" => to_string(!!user.manual_locked_trust_level)
        },
        as: :trust
      )

  defp penalty_form(params \\ %{"kind" => "silence", "duration" => "1w"}),
    do: to_form(params, as: :penalty)

  # Which permission each event needs (the account's for those about it).
  @permissions %{
    "save_account" => :manage_users,
    "approve" => :approve_user,
    "reject" => :approve_user,
    "set_trust_level" => :set_trust_level,
    "penalize" => :penalize_user,
    "lift" => :lift_penalty,
    "reset_two_factor" => :reset_two_factor,
    "set_role" => :manage_users,
    "add_group" => :manage_groups,
    "remove_group" => :manage_groups,
    "password_reset" => :manage_users,
    "sign_out" => :manage_users,
    "send_notification" => :manage_users,
    "delete_notification" => :manage_users,
    "revoke_api_key" => :manage_api_keys,
    "anonymize" => :manage_users,
    "delete" => :manage_users,
    "merge" => :manage_users
  }

  @impl true
  def handle_event(event, params, socket) when is_map_key(@permissions, event) do
    %{current_user: staff, user: user} = socket.assigns

    if can?(staff, @permissions[event], user),
      do: act(event, params, socket),
      else: {:noreply, put_flash(socket, :error, denied_message(staff))}
  end

  defp act("save_account", %{"user" => params}, socket) do
    case UserAdmin.update(socket.assigns.user, params, socket.assigns.current_user) do
      {:ok, _user} ->
        {:noreply, socket |> put_flash(:info, gettext("Account saved.")) |> reload()}

      {:error, changeset} ->
        {:noreply, assign(socket, :account_form, to_form(changeset))}
    end
  end

  defp act("approve", _params, socket) do
    socket.assigns.user
    |> UserAdmin.approve(socket.assigns.current_user)
    |> done(socket, gettext("Approved. They can post now."))
  end

  defp act("reject", _params, socket) do
    case UserAdmin.reject(socket.assigns.user, socket.assigns.current_user) do
      {:ok, _deleted} -> gone(socket, gettext("Rejected: the account was deleted."))
      {:error, reason} -> {:noreply, put_flash(socket, :error, UserAdmin.message(reason))}
    end
  end

  defp act("set_trust_level", %{"trust" => params}, socket) do
    %{current_user: staff, user: user} = socket.assigns

    case Integer.parse(params["level"] || "") do
      {level, ""} when level in 0..4 ->
        {:ok, _user} = TrustLevels.set_level(user, level, params["locked"] == "true", staff)
        {:noreply, socket |> put_flash(:info, gettext("Trust level set.")) |> reload()}

      _invalid ->
        {:noreply, put_flash(socket, :error, gettext("Pick a trust level."))}
    end
  end

  defp act("penalize", %{"penalty" => params}, socket) do
    kind = if params["kind"] == "suspend", do: :suspend, else: :silence

    case Penalties.penalize(kind, socket.assigns.user, socket.assigns.current_user, params) do
      {:ok, _user} ->
        {:noreply, socket |> put_flash(:info, gettext("Penalty applied.")) |> reload()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:penalty_form, penalty_form(params))
         |> put_flash(:error, Penalties.message(reason))}
    end
  end

  defp act("lift", %{"kind" => kind}, socket) do
    kind = if kind == "suspend", do: :suspend, else: :silence
    {:ok, _user} = Penalties.lift(kind, socket.assigns.user, socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, gettext("Lifted.")) |> reload()}
  end

  defp act("reset_two_factor", _params, socket) do
    {:ok, _} = TwoFactor.reset(socket.assigns.user, socket.assigns.current_user)

    {:noreply,
     socket |> put_flash(:info, gettext("Two-factor authentication was reset.")) |> reload()}
  end

  defp act("set_role", %{"role" => role, "grant" => grant}, socket)
       when role in ~w(admin moderator) do
    socket.assigns.user
    |> UserAdmin.set_staff_role(role, grant == "true", socket.assigns.current_user)
    |> done(socket, gettext("Roles saved."))
  end

  defp act("add_group", %{"group" => name}, socket) do
    %{current_user: staff, user: user} = socket.assigns

    case Groups.get_by_name(String.trim(name)) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("No group with that name."))}

      group ->
        group
        |> Groups.add_member(user.username, staff)
        |> done(socket, gettext("Added to %{group}.", group: group.name))
    end
  end

  defp act("remove_group", %{"role_id" => role_id}, socket) do
    group = Groups.get_group!(role_id)

    group
    |> Groups.remove_member(socket.assigns.user, socket.assigns.current_user)
    |> done(socket, gettext("Removed from %{group}.", group: group.name))
  end

  defp act("sign_out", _params, socket) do
    UserAdmin.sign_out_everywhere(socket.assigns.user, socket.assigns.current_user)
    {:noreply, put_flash(socket, :info, gettext("Signed them out of every device."))}
  end

  defp act("password_reset", _params, socket) do
    case UserAdmin.send_password_reset(socket.assigns.user, socket.assigns.current_user) do
      :ok ->
        {:noreply,
         put_flash(socket, :info, gettext("A password reset link was emailed to them."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, UserAdmin.message(reason))}
    end
  end

  defp act("send_notification", %{"notice" => params}, socket) do
    socket.assigns.user
    |> UserAdmin.send_notification(params, socket.assigns.current_user)
    |> done(socket, gettext("Notice sent."))
  end

  defp act("delete_notification", %{"id" => id}, socket) do
    socket.assigns.user
    |> UserAdmin.delete_notification(id, socket.assigns.current_user)
    |> done(socket, gettext("Notification deleted."))
  end

  defp act("revoke_api_key", %{"id" => id}, socket) do
    key = ApiKeys.get(id)

    if key && key.user_id == socket.assigns.user.id do
      key |> ApiKeys.revoke(socket.assigns.current_user) |> done(socket, gettext("Key revoked."))
    else
      {:noreply, put_flash(socket, :error, UserAdmin.message(:not_found))}
    end
  end

  defp act("anonymize", _params, socket) do
    case UserAdmin.anonymize(socket.assigns.user, socket.assigns.current_user) do
      {:ok, _} ->
        gone(socket, gettext("The account was anonymized. Its posts stay, under a placeholder."))

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, UserAdmin.message(reason))}
    end
  end

  defp act("delete", _params, socket) do
    case UserAdmin.delete(socket.assigns.user, socket.assigns.current_user) do
      {:ok, _} -> gone(socket, gettext("The account and its posts were deleted."))
      {:error, reason} -> {:noreply, put_flash(socket, :error, UserAdmin.message(reason))}
    end
  end

  defp act("merge", %{"target" => username}, socket) do
    %{current_user: staff, user: user} = socket.assigns
    name = username |> String.trim() |> String.trim_leading("@")

    with %User{} = target <- Accounts.get_user_by_username(name) || {:error, :no_such_user},
         {:ok, target} <- UserAdmin.merge(user, target, staff) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Merged into @%{username}.", username: target.username))
       |> push_navigate(to: ~p"/staff/users/#{target.id}")}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, UserAdmin.message(reason))}
    end
  end

  defp done({:ok, _}, socket, message),
    do: {:noreply, socket |> put_flash(:info, message) |> reload()}

  defp done({:error, reason}, socket, _message),
    do: {:noreply, put_flash(socket, :error, UserAdmin.message(reason))}

  defp gone(socket, message),
    do: {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: ~p"/staff/users")}

  defp provider_label(provider) do
    Auth.label(provider)
  rescue
    _unknown -> provider
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <header class="flex flex-wrap items-center gap-4">
        <.avatar user={@user} size="size-16" />
        <div class="min-w-0 flex-1">
          <h1 class="text-2xl font-bold">{@user.username}</h1>
          <p class="text-base-content/70">{@user.name}</p>
          <div id="user-badges" class="mt-1 flex flex-wrap gap-1">
            <span :for={role <- @roles} class="badge badge-sm badge-outline">{role}</span>
            <span :if={User.pending_approval?(@user)} class="badge badge-sm badge-warning">{gettext("waiting for approval")}</span>
            <span :if={User.suspended?(@user)} class="badge badge-sm badge-error">{gettext("suspended")}</span>
            <span :if={User.silenced?(@user)} class="badge badge-sm badge-warning">{gettext("silenced")}</span>
          </div>
        </div>
        <div class="flex flex-wrap gap-2">
          <.link navigate={~p"/users/#{@user}"} class="btn btn-sm">{gettext("Public profile")}</.link>
          <.link
            :if={can?(@current_user, :impersonate, @user)}
            id="impersonate"
            href={~p"/staff/users/#{@user.id}/impersonate"}
            method="post"
            data-confirm={gettext("See the site as this member? It's recorded in the staff log.")}
            class="btn btn-sm"
          >
            <.icon name="hero-eye" class="size-4" /> {gettext("Impersonate")}
          </.link>
        </div>
      </header>

      <section :if={User.pending_approval?(@user) and can?(@current_user, :approve_user)} id="approval" class="alert alert-warning">
        <.icon name="hero-clock" class="size-5" />
        <span>{gettext("This account waits for approval: it can read but not post.")}</span>
        <div class="flex gap-2">
          <button phx-click="approve" class="btn btn-sm btn-primary">{gettext("Approve")}</button>
          <button phx-click="reject" data-confirm={gettext("Reject and delete this account?")} class="btn btn-sm">
            {gettext("Reject")}
          </button>
        </div>
      </section>

      <section id="account" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-3">
          <h2 class="card-title">{gettext("Account")}</h2>
          <dl class="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-sm">
            <dt class="text-base-content/70">{gettext("Email")}</dt>
            <dd id="account-email">
              {@user.email || gettext("none")}
              <span :if={@user.email && User.confirmed?(@user)} class="badge badge-xs badge-success">{gettext("confirmed")}</span>
              <span :if={@user.email && !User.confirmed?(@user)} class="badge badge-xs">{gettext("unconfirmed")}</span>
            </dd>
            <dt class="text-base-content/70">{gettext("Joined")}</dt>
            <dd><.time_ago id="joined" at={@user.inserted_at} /></dd>
            <dt class="text-base-content/70">{gettext("Last seen")}</dt>
            <dd>
              <.time_ago :if={@user.last_seen_at} id="last-seen" at={@user.last_seen_at} />
              <span :if={!@user.last_seen_at}>{gettext("never")}</span>
            </dd>
            <dt class="text-base-content/70">{gettext("Posts")}</dt>
            <dd id="post-count">{gettext("%{posts} posts in %{threads} threads they started", posts: @counts.posts, threads: @counts.threads)}</dd>
            <dt class="text-base-content/70">{gettext("Logins")}</dt>
            <dd id="identities">
              <span :if={@user.password_hash} class="badge badge-sm">{gettext("password")}</span>
              <span :for={identity <- @identities} class="badge badge-sm">{provider_label(identity.provider)}</span>
              <span :if={@two_factor?} class="badge badge-sm badge-info">{gettext("two-factor")}</span>
              <button
                :if={@two_factor? and can?(@current_user, :reset_two_factor, @user)}
                phx-click="reset_two_factor"
                data-confirm={gettext("Turn off every second factor of this account?")}
                class="btn btn-ghost btn-xs"
              >
                {gettext("Reset two-factor")}
              </button>
            </dd>
          </dl>
          <.form
            :if={can?(@current_user, :manage_users, @user)}
            for={@account_form}
            id="account-form"
            phx-submit="save_account"
            class="grid gap-2 sm:grid-cols-3"
          >
            <.input field={@account_form[:username]} type="text" label={gettext("Username")} />
            <.input field={@account_form[:name]} type="text" label={gettext("Name")} />
            <.input field={@account_form[:email]} type="email" label={gettext("Email")} />
            <div class="sm:col-span-3 flex flex-wrap gap-2">
              <.button variant="primary" phx-disable-with={gettext("Saving...")}>{gettext("Save account")}</.button>
              <button
                type="button"
                phx-click="password_reset"
                data-confirm={gettext("Email this member a password reset link?")}
                class="btn"
              >
                {gettext("Send password reset")}
              </button>
              <button
                type="button"
                phx-click="sign_out"
                data-confirm={gettext("Sign this member out of every device?")}
                class="btn"
              >
                {gettext("Sign out everywhere")}
              </button>
            </div>
          </.form>
        </div>
      </section>

      <section id="permissions" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-3">
          <h2 class="card-title">{gettext("Trust and roles")}</h2>
          <.form
            :if={can?(@current_user, :set_trust_level, @user)}
            for={@trust_form}
            id="trust-level-form"
            phx-submit="set_trust_level"
            class="flex flex-wrap items-end gap-3"
          >
            <.input
              field={@trust_form[:level]}
              type="select"
              label={gettext("Trust level")}
              options={Enum.map(TrustLevels.levels(), &{TrustLevels.title(&1), &1})}
            />
            <.input field={@trust_form[:locked]} type="checkbox" label={gettext("Lock it (the automatic review leaves it alone)")} />
            <.button variant="primary" phx-disable-with={gettext("Saving...")}>{gettext("Set trust level")}</.button>
          </.form>
          <p :if={!can?(@current_user, :set_trust_level, @user)}>
            {TrustLevels.title(@user.trust_level)}
          </p>
          <div :if={can?(@current_user, :manage_users, @user)} id="staff-roles" class="flex flex-wrap gap-2">
            <%= for role <- ~w(admin moderator) do %>
              <button
                :if={role not in @roles}
                phx-click="set_role"
                phx-value-role={role}
                phx-value-grant="true"
                data-confirm={gettext("Make them %{role}?", role: role)}
                class="btn btn-sm"
              >
                {if role == "admin", do: gettext("Grant admin"), else: gettext("Grant moderator")}
              </button>
              <button
                :if={role in @roles}
                phx-click="set_role"
                phx-value-role={role}
                phx-value-grant="false"
                data-confirm={gettext("Take away their %{role} role?", role: role)}
                class="btn btn-sm"
              >
                {if role == "admin", do: gettext("Revoke admin"), else: gettext("Revoke moderator")}
              </button>
            <% end %>
          </div>
          <div id="groups">
            <h3 class="font-semibold">{gettext("Groups")}</h3>
            <ul class="mt-1 flex flex-wrap gap-2">
              <li :if={@groups == []} class="text-sm text-base-content/70">{gettext("None.")}</li>
              <li :for={group <- @groups} class="badge badge-outline gap-1">
                <.link navigate={~p"/groups/#{group.name}"}>{group.name}</.link>
                <button
                  :if={can?(@current_user, :manage_groups) and not Role.automatic?(group)}
                  phx-click="remove_group"
                  phx-value-role_id={group.id}
                  aria-label={gettext("Remove from %{group}", group: group.name)}
                  class="cursor-pointer"
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </li>
            </ul>
            <form :if={can?(@current_user, :manage_groups)} id="add-group" phx-submit="add_group" class="mt-2 flex gap-2">
              <input
                type="text"
                name="group"
                class="input input-sm"
                placeholder={gettext("Group name")}
                aria-label={gettext("Add to a group")}
              />
              <button class="btn btn-sm">{gettext("Add to group")}</button>
            </form>
          </div>
        </div>
      </section>

      <section id="penalties" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-3">
          <h2 class="card-title">{gettext("Penalties")}</h2>
          <p :if={!User.silenced?(@user) and !User.suspended?(@user)} class="text-sm text-base-content/70">
            {gettext("None in force.")}
          </p>
          <div :if={User.silenced?(@user)} id="silenced" class="flex flex-wrap items-center gap-2">
            <span class="badge badge-warning">{gettext("Silenced %{until}", until: Penalties.ends_text(@user.silenced_until))}</span>
            <span class="text-sm">{gettext("Reason: %{reason}", reason: @user.silence_reason)}</span>
            <button :if={can?(@current_user, :lift_penalty, @user)} phx-click="lift" phx-value-kind="silence" class="btn btn-ghost btn-xs">
              {gettext("Lift silence")}
            </button>
          </div>
          <div :if={User.suspended?(@user)} id="suspended" class="flex flex-wrap items-center gap-2">
            <span class="badge badge-error">{gettext("Suspended %{until}", until: Penalties.ends_text(@user.suspended_until))}</span>
            <span class="text-sm">{gettext("Reason: %{reason}", reason: @user.suspend_reason)}</span>
            <button :if={can?(@current_user, :lift_penalty, @user)} phx-click="lift" phx-value-kind="suspend" class="btn btn-ghost btn-xs">
              {gettext("Lift suspension")}
            </button>
          </div>
          <.form
            :if={can?(@current_user, :penalize_user, @user)}
            for={@penalty_form}
            id="penalty-form"
            phx-submit="penalize"
            class="space-y-2"
          >
            <div class="grid gap-4 sm:grid-cols-3">
              <.input
                field={@penalty_form[:kind]}
                type="select"
                label={gettext("Penalty")}
                options={[{gettext("Silence (can read, can't post)"), "silence"}, {gettext("Suspend (can't log in)"), "suspend"}]}
              />
              <.input field={@penalty_form[:duration]} type="select" label={gettext("Duration")} options={Penalties.durations()} />
              <.input field={@penalty_form[:until]} type="date" label={gettext("Until (for a date)")} />
            </div>
            <.input field={@penalty_form[:reason]} type="textarea" label={gettext("Reason (they see it)")} rows="2" />
            <.button variant="primary" phx-disable-with={gettext("Applying...")}>{gettext("Apply penalty")}</.button>
          </.form>
        </div>
      </section>

      <section id="ips" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-3">
          <h2 class="card-title">{gettext("IP addresses")}</h2>
          <p :if={@ips == []} class="text-sm text-base-content/70">{gettext("None recorded yet.")}</p>
          <table :if={@ips != []} class="table table-sm">
            <thead>
              <tr>
                <th>{gettext("Address")}</th>
                <th>{gettext("First seen")}</th>
                <th>{gettext("Last seen")}</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={{ip, index} <- Enum.with_index(@ips)}>
                <td>
                  <.link navigate={~p"/staff/users?#{%{q: ip.ip}}"} class="link font-mono">{ip.ip}</.link>
                </td>
                <td><.time_ago id={"ip-first-#{index}"} at={ip.first_seen_at} /></td>
                <td><.time_ago id={"ip-last-#{index}"} at={ip.last_seen_at} /></td>
              </tr>
            </tbody>
          </table>
          <p :if={@sharing != []} id="sharing" class="text-sm">
            {gettext("Also seen at these addresses:")}
            <.link :for={other <- @sharing} navigate={~p"/staff/users/#{other.id}"} class="link mr-2">@{other.username}</.link>
          </p>
        </div>
      </section>

      <section :if={can?(@current_user, :manage_api_keys)} id="api-keys" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-3">
          <h2 class="card-title">{gettext("API keys")}</h2>
          <p :if={@api_keys == []} class="text-sm text-base-content/70">{gettext("None.")}</p>
          <ul class="space-y-1">
            <li :for={key <- @api_keys} id={"api-key-#{key.id}"} class="flex flex-wrap items-center gap-2 text-sm">
              <span class="font-medium">{key.name}</span>
              <code>{key.prefix}…</code>
              <span class="text-base-content/70">{Enum.join(key.scopes, ", ")}</span>
              <span :if={key.revoked_at} class="badge badge-sm">{gettext("revoked")}</span>
              <button
                :if={!key.revoked_at}
                phx-click="revoke_api_key"
                phx-value-id={key.id}
                data-confirm={gettext("Revoke this key?")}
                class="btn btn-ghost btn-xs"
              >
                {gettext("Revoke")}
              </button>
            </li>
          </ul>
        </div>
      </section>

      <section :if={can?(@current_user, :manage_users, @user)} id="notifications" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-3">
          <h2 class="card-title">{gettext("Notifications")}</h2>
          <p class="text-sm text-base-content/70">{gettext("Their latest, without private messages.")}</p>
          <ul class="space-y-1">
            <li :for={notification <- @notifications} id={"notification-#{notification.id}"} class="flex items-center gap-2 text-sm">
              <span class="badge badge-sm">{notification.kind}</span>
              <span class="flex-1">{notification.subject}</span>
              <button
                phx-click="delete_notification"
                phx-value-id={notification.id}
                aria-label={gettext("Delete notification")}
                class="btn btn-ghost btn-xs"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </li>
          </ul>
          <.form for={@notice_form} id="notice-form" phx-submit="send_notification" class="grid gap-2 sm:grid-cols-2">
            <.input field={@notice_form[:subject]} type="text" label={gettext("Send a notice: subject")} />
            <.input field={@notice_form[:url]} type="text" label={gettext("Link (optional)")} />
            <div class="sm:col-span-2">
              <.input field={@notice_form[:body]} type="textarea" label={gettext("Message (optional)")} rows="2" />
            </div>
            <div><.button variant="primary" phx-disable-with={gettext("Sending...")}>{gettext("Send notice")}</.button></div>
          </.form>
        </div>
      </section>

      <section :if={can?(@current_user, :manage_users, @user)} id="danger-zone" class="card border border-error/40 bg-base-100">
        <div class="card-body gap-3">
          <h2 class="card-title">{gettext("Remove or merge")}</h2>
          <p class="text-sm text-base-content/70">
            {gettext("Anonymizing keeps their posts under a placeholder. Deleting also deletes the threads they started and their posts. Merging moves everything they own to another account and removes this one.")}
          </p>
          <div class="flex flex-wrap gap-2">
            <button
              phx-click="anonymize"
              data-confirm={gettext("Anonymize this account? This can't be undone.")}
              class="btn btn-sm btn-outline btn-error"
            >
              {gettext("Anonymize")}
            </button>
            <button
              phx-click="delete"
              data-confirm={gettext("Delete this account with its threads and posts? This can't be undone.")}
              class="btn btn-sm btn-error"
            >
              {gettext("Delete with posts")}
            </button>
          </div>
          <form id="merge-form" phx-submit="merge" class="flex flex-wrap items-center gap-2">
            <input
              type="text"
              name="target"
              class="input input-sm"
              placeholder={gettext("username")}
              aria-label={gettext("Account to merge into")}
            />
            <button
              class="btn btn-sm btn-outline btn-error"
              data-confirm={gettext("Merge this account into that one? This can't be undone.")}
            >
              {gettext("Merge into")}
            </button>
          </form>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
