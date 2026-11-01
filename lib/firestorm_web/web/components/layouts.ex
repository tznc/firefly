defmodule FirestormWeb.Web.Layouts do
  @moduledoc """
  The root HTML skeleton and the app layout (navbar, navigation drawer and
  flash messages) used by every page.
  """
  use FirestormWeb.Web, :html

  embed_templates "layouts/*"

  @doc """
  Renders the app layout.

      <Layouts.app flash={@flash} current_user={@current_user}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_user, :any, default: nil, doc: "the logged-in user, if any"
  attr :notification_count, :integer, default: 0
  attr :message_count, :integer, default: 0, doc: "conversations with unread messages"
  attr :current_path, :string, default: nil, doc: "used to highlight the active link"
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :contact_email, FirestormWeb.SiteSettings.get("contact_email"))

    ~H"""
    <div class="drawer lg:drawer-open">
      <input id="nav-drawer" type="checkbox" class="drawer-toggle" aria-label="Toggle navigation" />
      <div class="drawer-content flex min-h-screen flex-col">
        <header class="navbar sticky top-0 z-30 border-b border-base-300 bg-base-100/90 px-4 backdrop-blur sm:px-6">
          <div class="flex-1">
            <.link navigate={~p"/"} class="flex w-fit items-center gap-2">
              <.logo />
            </.link>
          </div>
          <div class="flex flex-none items-center gap-2">
            <form action={~p"/search"} method="get" role="search" class="hidden sm:block">
              <label class="input input-sm w-48 lg:w-64">
                <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
                <input type="search" name="q" placeholder="Search" aria-label="Search the forum" />
              </label>
            </form>
            <.link
              navigate={~p"/search"}
              class="btn btn-ghost btn-circle sm:hidden"
              aria-label="Search"
            >
              <.icon name="hero-magnifying-glass" class="size-5" />
            </.link>
            <.link
              :if={@current_user}
              navigate={~p"/notifications"}
              class="btn btn-ghost btn-circle"
              aria-label={"Notifications (#{@notification_count})"}
            >
              <div class="indicator">
                <.icon name="hero-bell" class="size-5" />
                <span
                  :if={@notification_count > 0}
                  class="badge badge-primary badge-xs indicator-item"
                >
                  {@notification_count}
                </span>
              </div>
            </.link>
            <.theme_toggle persist={!!@current_user} />
            <label for="nav-drawer" class="btn btn-ghost btn-square lg:hidden" aria-label="Open menu">
              <.icon name="hero-bars-3" class="size-6" />
            </label>
          </div>
        </header>

        <main class="flex-1 px-4 py-8 sm:px-6 lg:px-10">
          <div class="mx-auto max-w-4xl space-y-6">
            <.confirm_email_notice current_user={@current_user} />
            <.silenced_notice current_user={@current_user} />
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <div class="drawer-side z-40">
        <label for="nav-drawer" aria-label="Close menu" class="drawer-overlay"></label>
        <nav class="menu min-h-full w-64 gap-1 border-r border-base-300 bg-base-100 p-4">
          <%= if @current_user do %>
            <li class="menu-title">You</li>
            <.nav_item path={~p"/threads/watching"} current_path={@current_path} icon="hero-eye">
              Watching
            </.nav_item>
            <.nav_item
              path={~p"/threads/participating"}
              current_path={@current_path}
              icon="hero-chat-bubble-left-right"
            >
              Participating in
            </.nav_item>
            <.nav_item path={~p"/notifications"} current_path={@current_path} icon="hero-bell">
              Notifications
              <span :if={@notification_count > 0} class="badge badge-sm badge-primary">
                {@notification_count}
              </span>
            </.nav_item>
            <.nav_item path={~p"/messages"} current_path={@current_path} icon="hero-envelope">
              Messages
              <span
                :if={@message_count > 0}
                id="message-count"
                class="badge badge-sm badge-primary"
                aria-label={"#{@message_count} unread"}
              >
                {@message_count}
              </span>
            </.nav_item>
          <% end %>
          <li class="menu-title">Forum</li>
          <.nav_item path={~p"/"} current_path={@current_path} icon="hero-fire">Latest</.nav_item>
          <.nav_item path={~p"/categories"} current_path={@current_path} icon="hero-squares-2x2">
            Categories
          </.nav_item>
          <.nav_item path={~p"/tags"} current_path={@current_path} icon="hero-tag">Tags</.nav_item>
          <.nav_item path={~p"/users"} current_path={@current_path} icon="hero-users">Users</.nav_item>
          <li class="menu-title">Account</li>
          <%= if @current_user do %>
            <.nav_item
              path={~p"/users/#{@current_user}"}
              current_path={@current_path}
              icon="hero-user-circle"
            >
              Your profile
            </.nav_item>
            <.nav_item path={~p"/settings/profile"} current_path={@current_path} icon="hero-cog-6-tooth">
              Settings
            </.nav_item>
            <%= if FirestormWeb.Forums.admin?(@current_user) do %>
              <.nav_item
                path={~p"/staff/log"}
                current_path={@current_path}
                icon="hero-clipboard-document-list"
              >
                Staff log
              </.nav_item>
              <.nav_item
                path={~p"/staff/settings"}
                current_path={@current_path}
                icon="hero-adjustments-horizontal"
              >
                Site settings
              </.nav_item>
              <.nav_item path={~p"/staff/groups"} current_path={@current_path} icon="hero-user-group">
                Groups
              </.nav_item>
              <li>
                <a href="/admin"><.icon name="hero-wrench-screwdriver" class="size-5" /> Admin</a>
              </li>
            <% end %>
            <li>
              <.link href={~p"/auth/logout"} method="delete">
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" /> Log out
              </.link>
            </li>
          <% else %>
            <.nav_item
              path={~p"/login"}
              current_path={@current_path}
              icon="hero-arrow-right-end-on-rectangle"
            >
              Log in
            </.nav_item>
          <% end %>
          <li class="menu-title">About</li>
          <li :if={@contact_email != ""}>
            <a id="contact-email" href={"mailto:" <> @contact_email}>
              <.icon name="hero-envelope" class="size-5" /> Contact us
            </a>
          </li>
          <li><a href="https://tznc.dev">Made by tznc.dev</a></li>
          <li><a href="https://github.com/tznc/firefly">Firefly on GitHub</a></li>
          <li><a href="http://www.firestormforum.org">Built on Firestorm</a></li>
          <li><a href="http://www.firestormforum.org#patrons">Firestorm patrons</a></li>
        </nav>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :current_user, :any, required: true

  @doc "Asks a user with an unconfirmed email address to confirm it."
  def confirm_email_notice(assigns) do
    ~H"""
    <div
      :if={@current_user && @current_user.email && !FirestormWeb.Posting.confirmed_enough?(@current_user)}
      id="confirm-email-notice"
      role="alert"
      class="alert alert-warning"
    >
      <.icon name="hero-envelope" class="size-5" />
      <span>
        Confirm your email address to start posting. We sent a link to <strong>{@current_user.email}</strong>.
      </span>
      <.form for={%{}} action={~p"/confirm"} method="post">
        <button class="btn btn-sm">Resend link</button>
      </.form>
    </div>
    """
  end

  attr :current_user, :any, required: true

  @doc "Tells a silenced user what they can't do, why, and until when."
  def silenced_notice(assigns) do
    ~H"""
    <div
      :if={@current_user && FirestormWeb.Forums.User.silenced?(@current_user)}
      id="silenced-notice"
      role="alert"
      class="alert alert-warning"
    >
      <.icon name="hero-no-symbol" class="size-5" />
      <span>
        {FirestormWeb.Posting.message({:silenced, @current_user.silenced_until})}
        Reason: {@current_user.silence_reason}
      </span>
    </div>
    """
  end

  @doc """
  The assigns the app layout needs, taken from a LiveView's assigns:

      <Layouts.app {Layouts.shell(assigns)}>...</Layouts.app>
  """
  def shell(assigns) do
    Map.take(assigns, [:flash, :current_user, :notification_count, :message_count, :current_path])
  end

  attr :path, :string, required: true
  attr :current_path, :string, default: nil
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp nav_item(assigns) do
    ~H"""
    <li>
      <.link navigate={@path} class={@current_path == @path && "menu-active"}>
        <.icon name={@icon} class="size-5" />
        {render_slot(@inner_block)}
      </.link>
    </li>
    """
  end

  @doc "The Firefly icon and wordmark (the icon swaps for the dark theme)."
  attr :class, :string, default: nil
  attr :size, :string, default: "size-8"

  def logo(assigns) do
    ~H"""
    <span class={["flex items-center gap-2", @class]}>
      <img src={~p"/images/firefly-icon.svg"} alt="" class={[@size, "dark:hidden"]} />
      <img src={~p"/images/firefly-icon-dark.svg"} alt="" class={[@size, "hidden dark:block"]} />
      <span class="text-xl font-bold tracking-tight">{FirestormWeb.SiteSettings.get("title")}</span>
    </span>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  defp set_theme(theme, persist) do
    js = JS.dispatch("phx:set-theme")
    if persist, do: JS.push(js, "set_theme", value: %{theme: theme}), else: js
  end

  @doc """
  Light / dark / system theme toggle. See the script in root.html.heex.
  With `persist`, the choice is also saved as the user's theme (see
  `FirestormWeb.Web.UserAuth`).
  """
  attr :persist, :boolean, default: false

  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center rounded-full border-2 border-base-300 bg-base-300">
      <div class="absolute left-0 h-full w-1/3 rounded-full border-1 border-base-200 bg-base-100 brightness-200 transition-[left] [[data-theme=firefly]_&]:left-1/3 [[data-theme=firefly-dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0" />
      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={set_theme("system", @persist)}
        data-phx-theme="system"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={set_theme("light", @persist)}
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={set_theme("dark", @persist)}
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
