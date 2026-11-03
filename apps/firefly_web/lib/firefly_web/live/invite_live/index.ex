defmodule FireflyWeb.InviteLive.Index do
  @moduledoc """
  A member's invitations (see `Firefly.Accounts.Invites`): invite someone
  by email or make a link, see who redeemed each, resend or revoke them.
  Admins can also add a group and a landing thread, and see everyone's
  invites (`?all=true`).
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Accounts, Groups, SiteSettings, URLs}
  alias Firefly.Accounts.{Invite, Invites}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Invites")
     |> assign(:may_invite, Invites.may_invite?(user))
     |> assign(:staff, Accounts.admin?(user))
     |> assign(:groups, if(Accounts.admin?(user), do: Groups.list_groups(), else: []))
     |> assign(:kind, "email")
     |> assign(:form, to_form(Invites.change_invite(), as: :invite))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:all, socket.assigns.staff and params["all"] == "true") |> load()}
  end

  defp load(socket) do
    invites =
      if socket.assigns.all,
        do: Invites.list_all(),
        else: Invites.list_for(socket.assigns.current_user)

    assign(socket, :invites, invites)
  end

  @impl true
  def handle_event("kind", %{"kind" => kind}, socket) when kind in ["email", "link"],
    do:
      {:noreply,
       socket
       |> assign(:kind, kind)
       |> assign(:form, to_form(Invites.change_invite(), as: :invite))}

  def handle_event("save", %{"invite" => params}, socket) do
    params = if socket.assigns.kind == "link", do: Map.delete(params, "email"), else: params

    case Invites.create(socket.assigns.current_user, params) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> put_flash(:info, created_message(invite))
         |> assign(:form, to_form(Invites.change_invite(), as: :invite))
         |> load()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :invite, action: :insert))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Invites.message(reason))}
    end
  end

  def handle_event(event, %{"id" => id}, socket) when event in ["resend", "revoke"] do
    user = socket.assigns.current_user

    result =
      case Invites.get(id) do
        nil -> {:error, :not_allowed}
        invite when event == "resend" -> Invites.resend(invite, user)
        invite -> Invites.revoke(invite, user)
      end

    case result do
      {:ok, _invite} ->
        done = if event == "resend", do: "Invitation sent again.", else: "Invitation revoked."
        {:noreply, socket |> put_flash(:info, done) |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Invites.message(reason))}
    end
  end

  defp created_message(%Invite{email: nil}), do: "Invite link created."
  defp created_message(%Invite{email: email}), do: "Invitation sent to #{email}."

  defp status(invite) do
    case Invite.problem(invite) do
      nil -> {"Active", "badge-success"}
      :revoked -> {"Revoked", "badge-ghost"}
      :expired -> {"Expired", "badge-ghost"}
      :used_up -> {if(Invite.email?(invite), do: "Redeemed", else: "Used up"), "badge-info"}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Invites" navigate={~p"/invites"}>
        <:subtitle>Invite people to join, by email or with a link.</:subtitle>
        <:actions :if={@staff}>
          <.link patch={~p"/invites?#{[all: !@all]}"} class="btn btn-sm" id="toggle-all">
            {if @all, do: "My invites", else: "All invites"}
          </.link>
        </:actions>
      </.page_header>

      <p :if={!@may_invite} id="cannot-invite" class="alert alert-info">
        You can invite people once you reach trust level {SiteSettings.get("min_trust_to_invite")}.
      </p>

      <.form
        :if={@may_invite}
        for={@form}
        id="invite-form"
        phx-submit="save"
        class="card border border-base-300 bg-base-100"
      >
        <div class="card-body gap-2">
          <div role="tablist" class="tabs tabs-box w-fit">
            <button
              :for={{kind, label} <- [{"email", "By email"}, {"link", "Invite link"}]}
              type="button"
              role="tab"
              phx-click="kind"
              phx-value-kind={kind}
              class={["tab", @kind == kind && "tab-active"]}
            >
              {label}
            </button>
          </div>
          <.input :if={@kind == "email"} field={@form[:email]} type="email" label="Email" />
          <%= if @kind == "link" do %>
            <.input field={@form[:max_uses]} type="number" label="Uses" value={@form[:max_uses].value || 10} />
            <.input
              field={@form[:domain]}
              type="text"
              label="Only for addresses at (optional)"
              placeholder="example.com"
            />
          <% end %>
          <%= if @staff do %>
            <.input
              field={@form[:role_id]}
              type="select"
              label="Add to group (optional)"
              prompt="No group"
              options={Enum.map(@groups, &{&1.name, &1.id})}
            />
            <.input
              id="invite_thread"
              name="invite[thread]"
              value=""
              type="text"
              label="Land on thread (optional link or id)"
              errors={Enum.map(@form[:thread_id].errors, &translate_error/1)}
            />
          <% end %>
          <div class="flex justify-end">
            <.button variant="primary" phx-disable-with="Inviting...">
              {if @kind == "email", do: "Send invitation", else: "Create link"}
            </.button>
          </div>
        </div>
      </.form>

      <p :if={@invites == []} id="invites-empty" class="text-base-content/70">No invitations yet.</p>

      <ul :if={@invites != []} id="invites" class="space-y-2">
        <li
          :for={invite <- @invites}
          id={"invite-#{invite.id}"}
          class="rounded-box border border-base-300 bg-base-100 p-3 text-sm"
        >
          <div class="flex flex-wrap items-center gap-2">
            <span class={["badge badge-sm", elem(status(invite), 1)]}>{elem(status(invite), 0)}</span>
            <span :if={invite.email} class="font-medium">{invite.email}</span>
            <code :if={!invite.email} class="break-all">{URLs.invite_url(invite.key)}</code>
            <span class="text-base-content/70">
              {invite.uses}/{invite.max_uses} used<span :if={invite.domain}> · @{invite.domain} only</span><span :if={
                invite.role
              }> · joins {invite.role.name}</span>
              · expires <.time_ago id={"invite-#{invite.id}-expires"} at={invite.expires_at} />
            </span>
            <span :if={@all} class="text-base-content/70">by @{invite.invited_by.username}</span>
            <span class="flex-1"></span>
            <button
              :if={invite.email && Invite.problem(invite) in [nil, :expired]}
              phx-click="resend"
              phx-value-id={invite.id}
              class="btn btn-ghost btn-xs"
            >
              Resend
            </button>
            <button
              :if={Invite.problem(invite) in [nil, :expired]}
              phx-click="revoke"
              phx-value-id={invite.id}
              data-confirm="Revoke this invitation?"
              class="btn btn-ghost btn-xs text-error"
            >
              Revoke
            </button>
          </div>
          <p :if={invite.redemptions != []} class="mt-1 text-base-content/70">
            Redeemed by
            <.link :for={r <- invite.redemptions} navigate={~p"/users/#{r.user}"} class="link mr-1">
              @{r.user.username}
            </.link>
          </p>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
