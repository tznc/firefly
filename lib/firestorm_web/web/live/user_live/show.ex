defmodule FirestormWeb.Web.UserLive.Show do
  @moduledoc """
  A user's profile (bio, website, location) and their posts, paginated. Users
  can hide their posts and activity from others here; admins still see them.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.Forums

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = Forums.get_user!(id)

    {:ok,
     socket
     |> assign(:page_title, "#{user.username} - Users")
     |> assign(:user, user)
     |> assign(:activity?, activity_visible?(user, socket.assigns.current_user))
     |> assign(:last_post, Forums.user_last_post(user))
     |> assign(:last_seen, Forums.user_last_seen(user))}
  end

  defp activity_visible?(%{hide_profile_activity: false}, _viewer), do: true
  defp activity_visible?(_user, nil), do: false
  defp activity_visible?(%{id: id}, %{id: id}), do: true
  defp activity_visible?(_user, viewer), do: Forums.admin?(viewer)

  @impl true
  def handle_params(_params, _uri, %{assigns: %{activity?: false}} = socket),
    do: {:noreply, socket}

  def handle_params(params, _uri, socket) do
    posts_page = Forums.user_posts(socket.assigns.user, %{page: params["page"]})

    posts_page = %{
      posts_page
      | entries: Enum.map(posts_page.entries, &Forums.decorate_post_oembeds/1)
    }

    {:noreply, assign(socket, :posts_page, posts_page)}
  end

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

      <.markdown :if={@user.bio} id="user-bio" body={@user.bio} />

      <p :if={!@activity?} id="activity-hidden" class="text-base-content/60">
        {@user.username} keeps their activity private.
      </p>

      <div :if={@activity?} class="space-y-6">
        <ol id="user-posts" class="space-y-4">
          <li :for={post <- @posts_page.entries}>
            <.post post={post} thread={post.thread} headline />
          </li>
        </ol>

        <.pagination page={@posts_page} path={~p"/users/#{@user}"} />
      </div>
    </Layouts.app>
    """
  end
end
