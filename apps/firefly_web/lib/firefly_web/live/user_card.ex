defmodule FireflyWeb.UserCard do
  @moduledoc """
  The user card: clicking a post's avatar or username (on pages that
  render this component, with the post component's `card_target`) opens a
  card with the member's avatar, name, card background, the start of their
  bio, trust level (see `Firefly.TrustLevels`), title and best three
  badges (see `Firefly.Badges`), stats, when they
  joined and were last seen, and actions: message
  them, open their profile, mute or ignore them (see
  `Firefly.Accounts.Ignores`). A hidden profile (see `Firefly.Accounts.Profiles`)
  shows only the username and avatar. Muting or ignoring from the card
  sends the page `{:ignores_changed, viewer}`.

  Render it once per page and give posts `card_target="#user-card"`:

      <.live_component module={UserCard} id="user-card" current_user={@current_user} />
  """
  use FireflyWeb, :live_component

  alias Firefly.{Accounts, Badges, TrustLevels}
  alias Firefly.Accounts.{Ignores, Profiles}
  alias Firefly.Accounts.User

  @impl true
  def mount(socket), do: {:ok, assign(socket, :user, nil)}

  @impl true
  def handle_event("open", %{"user-id" => id}, socket) do
    case Accounts.get_user(id) do
      %User{} = user -> {:noreply, open(socket, user)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("close", _params, socket), do: {:noreply, assign(socket, :user, nil)}

  def handle_event("set_ignore", %{"ignore" => params}, %{assigns: %{ignorable?: true}} = socket) do
    %{current_user: viewer, user: user} = socket.assigns

    case Ignores.choose(viewer, user, params["level"], params["duration"]) do
      {:ok, message} ->
        # The page may collapse (or show again) the member's posts.
        send(self(), {:ignores_changed, viewer})
        {:noreply, socket |> open(user) |> assign(:notice, message)}

      {:error, message} ->
        {:noreply, assign(socket, :notice, message)}
    end
  end

  def handle_event("set_ignore", _params, socket), do: {:noreply, socket}

  defp open(socket, user) do
    viewer = socket.assigns.current_user
    visible? = Profiles.visible?(user, viewer)
    ignorable? = viewer != nil and viewer.id != user.id and not Accounts.admin?(user)

    socket
    |> assign(:user, user)
    |> assign(:visible?, visible?)
    |> assign(:stats, if(visible?, do: Profiles.stats(user)))
    |> assign(:badges, if(visible?, do: user |> Badges.user_badges() |> Enum.take(3), else: []))
    |> assign(:title, if(visible?, do: Badges.title(user)))
    |> assign(:ignorable?, ignorable?)
    |> assign(:ignore_level, if(ignorable?, do: Ignores.level(viewer, user)))
    |> assign(:notice, nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div :if={@user} class="modal modal-open" role="dialog" aria-label={"@#{@user.username}"}>
        <div id={"#{@id}-box"} class="modal-box max-w-md overflow-hidden p-0">
          <div
            class="h-24 bg-base-300 bg-cover bg-center"
            style={card_style(@visible? && User.background_url(@user, :card_background))}
          >
          </div>
          <div class="space-y-3 p-5">
            <div class="-mt-14 flex items-end gap-3">
              <div class="rounded-full bg-base-100 p-1"><.avatar user={@user} size="size-20" /></div>
              <div class="min-w-0 pb-1">
                <p class="truncate text-lg font-bold">@{@user.username}</p>
                <span :if={@title} class="user-card-title block text-sm text-primary">{@title}</span>
                <span :if={@visible?} class="user-card-trust badge badge-ghost badge-sm">
                  {TrustLevels.name(@user.trust_level)}
                </span>
                <p :if={@visible? && @user.name != @user.username} class="truncate text-sm text-base-content/70">
                  {@user.name}
                </p>
              </div>
            </div>
            <p :if={!@visible?} class="text-sm text-base-content/60">This profile is private.</p>
            <p :if={@visible? && Profiles.bio_excerpt(@user)} class="user-card-bio text-sm">
              {Profiles.bio_excerpt(@user)}
            </p>
            <dl :if={@visible?} class="grid grid-cols-3 gap-2 text-center text-sm">
              <div><dt class="text-xs text-base-content/60">Topics</dt><dd class="font-semibold">{@stats.topic_count}</dd></div>
              <div><dt class="text-xs text-base-content/60">Replies</dt><dd class="font-semibold">{@stats.post_count}</dd></div>
              <div><dt class="text-xs text-base-content/60">Likes</dt><dd class="font-semibold">{@stats.likes_received}</dd></div>
            </dl>
            <div :if={@badges != []} class="user-card-badges flex flex-wrap gap-2">
              <.link
                :for={{badge, _count, _at} <- @badges}
                navigate={~p"/badges/#{badge.id}"}
                class="flex items-center gap-1 text-sm"
              >
                <.badge_icon badge={badge} size="size-4" /> {badge.name}
              </.link>
            </div>
            <p :if={@visible?} class="flex flex-wrap gap-x-4 text-xs text-base-content/70">
              <span>Joined {short_date(@user.inserted_at)}</span>
              <span :if={@user.last_seen_at}>
                Last seen <.time_ago id={"#{@id}-seen"} at={@user.last_seen_at} />
              </span>
            </p>
            <div class="flex flex-wrap gap-2">
              <.link navigate={~p"/users/#{@user}"} class="btn btn-sm">
                <.icon name="hero-user" class="size-4" /> Profile
              </.link>
              <.link
                :if={@current_user && @current_user.id != @user.id && @user.allow_private_messages}
                navigate={~p"/messages/new?#{[to: @user.username]}"}
                class="btn btn-primary btn-sm"
              >
                <.icon name="hero-envelope" class="size-4" /> Message
              </.link>
            </div>
            <p :if={@notice} role="status" class="text-sm text-info">{@notice}</p>
            <.ignore_form
              :if={@ignorable?}
              id={"#{@id}-ignore"}
              user={@user}
              level={@ignore_level}
              target={@myself}
            />
          </div>
        </div>
        <div class="modal-backdrop" phx-click="close" phx-target={@myself}></div>
      </div>
    </div>
    """
  end

  defp card_style(nil), do: nil
  defp card_style(false), do: nil
  defp card_style(url), do: "background-image: url('#{url}')"
end
