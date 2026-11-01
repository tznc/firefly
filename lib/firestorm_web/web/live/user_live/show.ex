defmodule FirestormWeb.Web.UserLive.Show do
  @moduledoc "A user's profile and their posts, paginated."
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{Forums, Mentions}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = Forums.get_user!(id)

    {:ok,
     socket
     |> assign(:page_title, "#{user.username} - Users")
     |> assign(:user, user)
     |> assign(:last_post, Forums.user_last_post(user))
     |> assign(:last_seen, Forums.user_last_seen(user))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    posts_page = Forums.user_posts(socket.assigns.user, %{page: params["page"]})

    posts_page = %{
      posts_page
      | entries: Enum.map(posts_page.entries, &Forums.decorate_post_oembeds/1)
    }

    {:noreply,
     socket
     |> assign(:posts_page, posts_page)
     |> assign(:refs, Mentions.refs(Enum.map(posts_page.entries, & &1.body)))}
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
            <dl class="flex flex-wrap gap-x-6 gap-y-1 pt-2 text-sm">
              <div><dt class="inline font-semibold">Joined</dt> <dd class="inline">{short_date(@user.inserted_at)}</dd></div>
              <div :if={@last_post}>
                <dt class="inline font-semibold">Last post</dt>
                <dd class="inline">{short_date(@last_post.inserted_at)}</dd>
              </div>
              <div :if={@last_seen}>
                <dt class="inline font-semibold">Last seen</dt>
                <dd class="inline">{short_date(@last_seen)}</dd>
              </div>
            </dl>
          </div>
          <.link
            :if={@current_user && @current_user.id == @user.id}
            navigate={~p"/users/#{@user}/edit"}
            class="btn btn-ghost btn-sm"
            aria-label="Edit profile"
          >
            <.icon name="hero-cog-6-tooth" class="size-5" /> Edit
          </.link>
        </div>
      </section>

      <ol id="user-posts" class="space-y-4">
        <li :for={post <- @posts_page.entries}>
          <.post post={post} thread={post.thread} refs={@refs} headline />
        </li>
      </ol>

      <.pagination page={@posts_page} path={~p"/users/#{@user}"} />
    </Layouts.app>
    """
  end
end
