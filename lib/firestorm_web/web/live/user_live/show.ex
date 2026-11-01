defmodule FirestormWeb.Web.UserLive.Show do
  @moduledoc """
  A user's profile (bio, website, location) and their posts, paginated. Users
  can hide their posts and activity from others here; admins still see them.
  Admins see a member's penalties here, and silence or suspend them (see
  `FirestormWeb.Penalties`).
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{Forums, Penalties}
  alias FirestormWeb.Forums.User

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = Forums.get_user!(id)

    {:ok,
     socket
     |> assign(:page_title, "#{user.username} - Users")
     |> assign(:user, user)
     |> assign(:staff?, staff?(socket.assigns.current_user))
     |> assign(:penalty_form, penalty_form())
     |> assign(:activity?, activity_visible?(user, socket.assigns.current_user))
     |> assign(:last_post, Forums.user_last_post(user, socket.assigns.current_user))
     |> assign(:last_seen, Forums.user_last_seen(user))}
  end

  defp staff?(nil), do: false
  defp staff?(viewer), do: Forums.admin?(viewer)

  defp activity_visible?(%{hide_profile_activity: false}, _viewer), do: true
  defp activity_visible?(_user, nil), do: false
  defp activity_visible?(%{id: id}, %{id: id}), do: true
  defp activity_visible?(_user, viewer), do: Forums.admin?(viewer)

  @impl true
  def handle_params(_params, _uri, %{assigns: %{activity?: false}} = socket),
    do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    %{user: user, current_user: viewer} = socket.assigns
    posts_page = Forums.user_posts(user, viewer, %{page: params["page"]})

    posts_page = %{
      posts_page
      | entries: Enum.map(posts_page.entries, &Forums.decorate_post_oembeds/1)
    }

    {:noreply, assign(socket, :posts_page, posts_page)}
  end

  defp penalty_form(params \\ %{"kind" => "silence", "duration" => "1w"}),
    do: to_form(params, as: :penalty)

  @impl true
  def handle_event(event, params, socket) when event in ["penalize", "lift"] do
    %{current_user: admin, user: user} = socket.assigns

    if can?(admin, :penalize_user, user),
      do: penalty_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, denied_message(admin))}
  end

  defp penalty_event("penalize", %{"penalty" => params}, socket) do
    %{current_user: admin, user: user} = socket.assigns
    kind = if params["kind"] == "suspend", do: :suspend, else: :silence

    case Penalties.penalize(kind, user, admin, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign(user: user, penalty_form: penalty_form())
         |> put_flash(:info, "#{user.username} is #{penalty_text(kind, user)}.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:penalty_form, penalty_form(params))
         |> put_flash(:error, Penalties.message(reason))}
    end
  end

  defp penalty_event("lift", %{"kind" => kind}, socket) do
    kind = if kind == "suspend", do: :suspend, else: :silence
    {:ok, user} = Penalties.lift(kind, socket.assigns.user, socket.assigns.current_user)
    {:noreply, socket |> assign(:user, user) |> put_flash(:info, "Lifted.")}
  end

  defp penalty_text(:silence, user), do: "silenced #{Penalties.ends_text(user.silenced_until)}"
  defp penalty_text(:suspend, user), do: "suspended #{Penalties.ends_text(user.suspended_until)}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="card border border-base-300 bg-base-100">
        <div class="card-body flex-row flex-wrap items-center gap-6">
          <.avatar user={@user} size="size-24" />
          <div class="min-w-0 flex-1 space-y-1">
            <h1 class="text-2xl font-bold">{@user.username}</h1>
            <p :if={@user.name} class="text-base-content/70">{@user.name}</p>
            <p :if={@user.location || @user.website} class="flex flex-wrap gap-x-4 text-sm">
              <span :if={@user.location} id="user-location">
                <.icon name="hero-map-pin" class="size-4 opacity-60" /> {@user.location}
              </span>
              <a
                :if={@user.website}
                id="user-website"
                href={@user.website}
                rel="nofollow ugc noopener"
                class="link link-hover"
              >
                <.icon name="hero-link" class="size-4 opacity-60" /> {URI.parse(@user.website).host}
              </a>
            </p>
            <dl class="flex flex-wrap gap-x-6 gap-y-1 pt-2 text-sm">
              <div><dt class="inline font-semibold">Joined</dt> <dd class="inline">{short_date(@user.inserted_at)}</dd></div>
              <div :if={@activity? && @last_post}>
                <dt class="inline font-semibold">Last post</dt>
                <dd class="inline">{short_date(@last_post.inserted_at)}</dd>
              </div>
              <div :if={@activity? && @last_seen}>
                <dt class="inline font-semibold">Last seen</dt>
                <dd class="inline">{short_date(@last_seen)}</dd>
              </div>
            </dl>
          </div>
          <.link
            :if={@current_user && @current_user.id != @user.id && @user.allow_private_messages}
            navigate={~p"/messages/new?#{[to: @user.username]}"}
            class="btn btn-primary btn-sm"
          >
            <.icon name="hero-envelope" class="size-5" /> Message
          </.link>
          <.link
            :if={@current_user && @current_user.id == @user.id}
            navigate={~p"/settings/profile"}
            class="btn btn-ghost btn-sm"
            aria-label="Edit profile"
          >
            <.icon name="hero-cog-6-tooth" class="size-5" /> Edit
          </.link>
        </div>
      </section>

      <div :if={@staff?} id="penalties" class="space-y-2">
        <div :if={User.silenced?(@user)} id="silenced-badge" class="flex flex-wrap items-center gap-2">
          <span class="badge badge-warning">Silenced {Penalties.ends_text(@user.silenced_until)}</span>
          <span class="text-sm">Reason: {@user.silence_reason}</span>
          <button
            :if={can?(@current_user, :penalize_user, @user)}
            phx-click="lift"
            phx-value-kind="silence"
            class="btn btn-ghost btn-xs"
          >
            Lift silence
          </button>
        </div>
        <div :if={User.suspended?(@user)} id="suspended-badge" class="flex flex-wrap items-center gap-2">
          <span class="badge badge-error">Suspended {Penalties.ends_text(@user.suspended_until)}</span>
          <span class="text-sm">Reason: {@user.suspend_reason}</span>
          <button
            :if={can?(@current_user, :penalize_user, @user)}
            phx-click="lift"
            phx-value-kind="suspend"
            class="btn btn-ghost btn-xs"
          >
            Lift suspension
          </button>
        </div>
        <details :if={can?(@current_user, :penalize_user, @user)} class="collapse-arrow collapse border border-base-300 bg-base-100">
          <summary class="collapse-title font-semibold">Silence or suspend</summary>
          <div class="collapse-content">
            <.form for={@penalty_form} id="penalty-form" phx-submit="penalize" class="space-y-2">
              <div class="grid gap-4 sm:grid-cols-3">
                <.input
                  field={@penalty_form[:kind]}
                  type="select"
                  label="Penalty"
                  options={[{"Silence (can read, can't post)", "silence"}, {"Suspend (can't log in)", "suspend"}]}
                />
                <.input
                  field={@penalty_form[:duration]}
                  type="select"
                  label="Duration"
                  options={Penalties.durations()}
                />
                <.input field={@penalty_form[:until]} type="date" label="Until (for a date)" />
              </div>
              <.input
                field={@penalty_form[:reason]}
                type="textarea"
                label="Reason (the user sees it)"
                rows="2"
              />
              <.button variant="primary" phx-disable-with="Applying...">Apply penalty</.button>
            </.form>
          </div>
        </details>
      </div>

      <.markdown :if={@user.bio} id="user-bio" body={@user.bio} />

      <p :if={!@activity?} id="activity-hidden" class="text-base-content/60">
        {@user.username} keeps their activity private.
      </p>

      <div :if={@activity?} class="space-y-6">
        <ol id="user-posts" class="space-y-4">
          <li :for={post <- @posts_page.entries}>
            <.post post={post} thread={post.thread} viewer={@current_user} headline />
          </li>
        </ol>

        <.pagination page={@posts_page} path={~p"/users/#{@user}"} />
      </div>
    </Layouts.app>
    """
  end
end
