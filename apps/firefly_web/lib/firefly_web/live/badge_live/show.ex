defmodule FireflyWeb.BadgeLive.Show do
  @moduledoc """
  A badge's page: what it's for, and who has it, newest first, with the
  post it was granted for when the viewer may read it. Admins grant it
  here (to a username, with a reason) and revoke grants (see
  `Firefly.Badges`).
  """
  use FireflyWeb, :live_view

  alias Firefly.{Accounts, Badges}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    staff? = can?(socket.assigns.current_user, :manage_badges)
    # Staff also open disabled badges, from the badges admin page.
    badge = if staff?, do: Badges.get_badge!(id), else: Badges.get_enabled!(id)

    {:ok,
     socket
     |> assign(:page_title, "#{badge.name} - Badges")
     |> FireflyWeb.SEO.assign(%{
       title: badge.name,
       description: badge.description,
       canonical: Firefly.URLs.badge_url(badge),
       noindex: not Firefly.SEO.index_user_pages?()
     })
     |> assign(:badge, badge)
     |> assign(:staff?, staff?)
     |> assign(:grant_form, to_form(%{}, as: :grant))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    %{badge: badge, current_user: viewer} = socket.assigns
    {:noreply, assign(socket, :grants, Badges.grantees(badge, viewer, params["page"]))}
  end

  @impl true
  def handle_event("grant", %{"grant" => params}, %{assigns: %{staff?: true}} = socket) do
    %{badge: badge, current_user: admin} = socket.assigns
    username = params |> Map.get("username", "") |> String.trim() |> String.trim_leading("@")

    with %{} = user <-
           Accounts.users_by_username([username])[String.downcase(username)] || :no_user,
         {:ok, _} <- Badges.grant(badge, user, admin, params["reason"]) do
      {:noreply,
       socket
       |> put_flash(:info, "Granted #{badge.name} to @#{user.username}.")
       |> assign(:grants, Badges.grantees(badge, admin, 1))}
    else
      :no_user -> {:noreply, put_flash(socket, :error, "No user with that username.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Badges.message(reason))}
    end
  end

  def handle_event("revoke", %{"id" => id}, %{assigns: %{staff?: true}} = socket) do
    %{badge: badge, current_user: admin} = socket.assigns

    case Badges.revoke(id, admin) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Revoked.")
         |> assign(:grants, Badges.grantees(badge, admin, 1))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Badges.message(reason))}
    end
  end

  def handle_event(_event, _params, socket),
    do: {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.link navigate={~p"/badges"} class="link link-hover text-sm">← All badges</.link>
      <section class="flex items-start gap-4">
        <.badge_icon badge={@badge} size="size-10" />
        <div>
          <h1 class="text-2xl font-bold">{@badge.name}</h1>
          <p class="text-base-content/70">{@badge.description}</p>
          <p class="text-sm text-base-content/60">
            {String.capitalize(@badge.badge_type)} badge{if @badge.allow_title, do: " · can be used as a title"}
          </p>
        </div>
      </section>

      <.form
        :if={@staff?}
        for={@grant_form}
        id="grant-form"
        phx-submit="grant"
        class="flex flex-wrap items-end gap-2"
      >
        <.input field={@grant_form[:username]} type="text" label="Grant to (username)" />
        <.input field={@grant_form[:reason]} type="text" label="Reason (optional)" />
        <.button phx-disable-with="Granting...">Grant</.button>
      </.form>

      <p :if={@grants.entries == []} class="text-base-content/70">Nobody has this badge yet.</p>
      <ul id="grantees" class="list rounded-box border border-base-300 bg-base-100">
        <li :for={grant <- @grants.entries} id={"grant-#{grant.id}"} class="list-row items-center">
          <.avatar user={grant.user} size="size-8" />
          <div class="list-col-grow min-w-0">
            <.link navigate={~p"/users/#{grant.user}"} class="font-medium hover:text-primary">
              @{grant.user.username}
            </.link>
            <span class="text-sm text-base-content/60">{short_date(grant.granted_at)}</span>
            <.link
              :if={grant.post}
              navigate={~p"/categories/#{grant.post.thread.category_id}/threads/#{grant.post.thread}" <> "#post-#{grant.post.id}"}
              class="block truncate text-sm hover:text-primary"
            >
              {grant.post.thread.title}
            </.link>
            <span :if={@staff? && grant.reason} class="block text-sm italic">{grant.reason}</span>
          </div>
          <button
            :if={@staff?}
            phx-click="revoke"
            phx-value-id={grant.id}
            data-confirm={"Revoke #{@badge.name} from @#{grant.user.username}?"}
            class="btn btn-ghost btn-xs text-error"
          >
            Revoke
          </button>
        </li>
      </ul>

      <.pagination page={@grants} path={~p"/badges/#{@badge.id}"} params={%{}} />
    </Layouts.app>
    """
  end
end
