defmodule FireflyWeb.Layouts do
  @moduledoc """
  The root HTML skeleton and the app layout (navbar, navigation drawer and
  flash messages) used by every page.
  """
  use FireflyWeb, :html

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
  attr :review_count, :integer, default: 0, doc: "items in the staff review queue (admins)"
  attr :read_only, :map, default: nil, doc: "the site's read-only state (see `Firefly.Backups`)"
  attr :chat, :boolean, default: false, doc: "the user may chat (see `Firefly.Chat`)"
  attr :shortcuts, :boolean, default: true, doc: "keyboard shortcuts are on for this reader"

  attr :full, :boolean,
    default: false,
    doc: "the page fills the space next to the navigation (no margins, as chat)"

  attr :staff, :boolean,
    default: false,
    doc: "a page of the staff admin: the sidebar shows the admin's sections"

  attr :impersonator, :any,
    default: nil,
    doc: "the admin seeing the site as `current_user`, if any (a banner offers to stop)"

  attr :update_available, :boolean,
    default: false,
    doc: "a newer Firefly is out (admins; see `Firefly.Upgrades`)"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :contact_email, Firefly.SiteSettings.get("contact_email"))

    ~H"""
    <div class="drawer lg:drawer-open" id="shell" phx-hook="KeyboardShortcuts" data-shortcuts={to_string(@shortcuts)}>
      <input id="nav-drawer" type="checkbox" class="drawer-toggle" aria-label={gettext("Toggle navigation")} />
      <div class="drawer-content flex min-h-screen flex-col">
        <a href="#main" class="skip-link btn btn-sm btn-primary">{gettext("Skip to content")}</a>
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
                <input type="search" name="q" placeholder={gettext("Search")} aria-label={gettext("Search the forum")} />
              </label>
            </form>
            <.link
              navigate={~p"/search"}
              class="btn btn-ghost btn-circle sm:hidden"
              aria-label={gettext("Search")}
            >
              <.icon name="hero-magnifying-glass" class="size-5" />
            </.link>
            <.link
              :if={@current_user}
              navigate={~p"/notifications"}
              class="btn btn-ghost btn-circle"
              aria-label={gettext("Notifications (%{count})", count: @notification_count)}
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
            <label for="nav-drawer" class="btn btn-ghost btn-square lg:hidden" aria-label={gettext("Open menu")}>
              <.icon name="hero-bars-3" class="size-6" />
            </label>
          </div>
        </header>

        <main id="main" class={["flex-1", !@full && "px-4 py-8 sm:px-6 lg:px-10", @full && "min-h-0"]}>
          <div class={[!@full && "mx-auto max-w-4xl space-y-6", @full && "flex h-full flex-col"]}>
            <div :if={@read_only} id="read-only-banner" role="status" class="alert alert-warning">
              <.icon name="hero-lock-closed" class="size-5" />
              <span>
                {gettext("The forum is read-only for maintenance (%{reason}). You can read, but not post or change anything for now.", reason: @read_only.reason)}
              </span>
            </div>
            <.impersonation_banner :if={@impersonator} current_user={@current_user} />
            <.confirm_email_notice current_user={@current_user} />
            <.silenced_notice current_user={@current_user} />
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <div class="drawer-side z-40">
        <label for="nav-drawer" aria-hidden="true" class="drawer-overlay"></label>
        <.staff_nav
          :if={@staff}
          current_user={@current_user}
          current_path={@current_path}
          review_count={@review_count}
          update_available={@update_available}
        />
        <nav :if={!@staff} aria-label={gettext("Forum navigation")} class="min-h-full w-64 border-r border-base-300 bg-base-100 p-4">
          <label for="nav-drawer" class="btn btn-ghost btn-sm mb-2 lg:hidden">
            <.icon name="hero-x-mark" class="size-5" /> {gettext("Close menu")}
          </label>
          <ul class="menu w-full gap-1 p-0">
          <%= if @current_user do %>
            <li class="menu-title">{gettext("You")}</li>
            <.nav_item path={~p"/threads/watching"} current_path={@current_path} icon="hero-eye">
              {gettext("Watching")}
            </.nav_item>
            <.nav_item
              path={~p"/threads/participating"}
              current_path={@current_path}
              icon="hero-chat-bubble-left-right"
            >
              {gettext("Participating in")}
            </.nav_item>
            <.nav_item path={~p"/drafts"} current_path={@current_path} icon="hero-pencil-square">
              {gettext("Drafts")}
            </.nav_item>
            <.nav_item path={~p"/bookmarks"} current_path={@current_path} icon="hero-bookmark">
              {gettext("Bookmarks")}
            </.nav_item>
            <.nav_item path={~p"/notifications"} current_path={@current_path} icon="hero-bell">
              {gettext("Notifications")}
              <span :if={@notification_count > 0} class="badge badge-sm badge-primary">
                {@notification_count}
              </span>
            </.nav_item>
            <.nav_item path={~p"/messages"} current_path={@current_path} icon="hero-envelope">
              {gettext("Messages")}
              <span
                :if={@message_count > 0}
                id="message-count"
                class="badge badge-sm badge-primary"
                aria-label={gettext("%{count} unread", count: @message_count)}
              >
                {@message_count}
              </span>
            </.nav_item>
            <.nav_item :if={@chat} path={~p"/chat"} current_path={@current_path} icon="hero-chat-bubble-oval-left-ellipsis">
              {gettext("Chat")}
            </.nav_item>
          <% end %>
          <li class="menu-title">{gettext("Forum")}</li>
          <.nav_item path={~p"/"} current_path={@current_path} icon="hero-fire">{gettext("Latest")}</.nav_item>
          <.nav_item path={~p"/categories"} current_path={@current_path} icon="hero-squares-2x2">
            {gettext("Categories")}
          </.nav_item>
          <.nav_item path={~p"/tags"} current_path={@current_path} icon="hero-tag">{gettext("Tags")}</.nav_item>
          <.nav_item path={~p"/users"} current_path={@current_path} icon="hero-users">{gettext("Users")}</.nav_item>
          <.nav_item path={~p"/groups"} current_path={@current_path} icon="hero-user-group">
            {gettext("Groups")}
          </.nav_item>
          <.nav_item path={~p"/badges"} current_path={@current_path} icon="hero-trophy">
            {gettext("Badges")}
          </.nav_item>
          <li class="menu-title">{gettext("Account")}</li>
          <%= if @current_user do %>
            <.nav_item
              path={~p"/users/#{@current_user}"}
              current_path={@current_path}
              icon="hero-user-circle"
            >
              {gettext("Your profile")}
            </.nav_item>
            <.nav_item path={~p"/settings/profile"} current_path={@current_path} icon="hero-cog-6-tooth">
              {gettext("Settings")}
            </.nav_item>
            <.nav_item
              :if={Firefly.Accounts.Invites.may_invite?(@current_user)}
              path={~p"/invites"}
              current_path={@current_path}
              icon="hero-envelope"
            >
              {gettext("Invites")}
            </.nav_item>
            <%= if Firefly.Accounts.staff?(@current_user) do %>
              <.nav_item path={~p"/staff"} current_path={@current_path} icon="hero-wrench-screwdriver">
                {gettext("Admin")}
                <span :if={@update_available} id="update-badge" class="badge badge-sm badge-info">
                  {gettext("new")}
                </span>
              </.nav_item>
              <.nav_item path={~p"/staff/review"} current_path={@current_path} icon="hero-inbox-stack">
                {gettext("Review")}
                <span
                  :if={@review_count > 0}
                  id="review-count"
                  class="badge badge-sm badge-warning"
                  aria-label={gettext("%{count} to review", count: @review_count)}
                >
                  {@review_count}
                </span>
              </.nav_item>
            <% end %>
            <li>
              <.link href={~p"/auth/logout"} method="delete">
                <.icon name="hero-arrow-right-start-on-rectangle" class="size-5" /> {gettext("Log out")}
              </.link>
            </li>
          <% else %>
            <.nav_item
              path={~p"/login"}
              current_path={@current_path}
              icon="hero-arrow-right-end-on-rectangle"
            >
              {gettext("Log in")}
            </.nav_item>
          <% end %>
            <li>
              <FireflyWeb.PluginComponents.plugin_outlet
                outlet="sidebar"
                key="nav"
                user={@current_user}
              />
            </li>
          <li class="menu-title">{gettext("About")}</li>
          <li :if={@contact_email != ""}>
            <a id="contact-email" href={"mailto:" <> @contact_email}>
              <.icon name="hero-envelope" class="size-5" /> {gettext("Contact us")}
            </a>
          </li>
          <li><a href="https://tznc.dev">{gettext("Made by tznc.dev")}</a></li>
          <li><a href="https://github.com/tznc/firefly">{gettext("Firefly on GitHub")}</a></li>
          <li><a href="http://www.firestormforum.org">{gettext("Built on Firestorm")}</a></li>
          <li><a href="http://www.firestormforum.org#patrons">{gettext("Firestorm patrons")}</a></li>
          </ul>
        </nav>
      </div>
    </div>

    <.shortcuts_help />
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The keyboard shortcuts, in a modal the `KeyboardShortcuts` hook opens
  with `?` (a native `dialog`, so the browser traps focus and Escape
  closes it).
  """
  def shortcuts_help(assigns) do
    assigns =
      assign(assigns, :shortcuts, [
        {"?", gettext("Show this help")},
        {"j / k", gettext("Next / previous topic or post")},
        {"g h", gettext("Home")},
        {"g c", gettext("Categories")},
        {"g n", gettext("New topics")},
        {"g u", gettext("Unread topics")},
        {"g t", gettext("Top topics")},
        {"g b", gettext("Bookmarks")},
        {"g m", gettext("Messages")},
        {"g p", gettext("Chat")},
        {"r", gettext("Reply")},
        {"l", gettext("Like the post in hand")},
        {"b", gettext("Bookmark the post in hand")},
        {"/", gettext("Search")},
        {"Esc", gettext("Close")}
      ])

    ~H"""
    <dialog id="shortcuts-help" class="modal" aria-labelledby="shortcuts-help-title">
      <div class="modal-box">
        <h2 id="shortcuts-help-title" class="text-lg font-semibold">{gettext("Keyboard shortcuts")}</h2>
        <dl class="mt-3 grid grid-cols-[auto_1fr] gap-x-4 gap-y-2 text-sm">
          <div :for={{keys, description} <- @shortcuts} class="col-span-2 grid grid-cols-subgrid">
            <dt><kbd class="kbd kbd-sm">{keys}</kbd></dt>
            <dd>{description}</dd>
          </div>
        </dl>
        <p class="mt-4 text-xs text-base-content/70">
          {gettext("Turn these off in your interface settings.")}
        </p>
        <div class="modal-action">
          <form method="dialog">
            <button class="btn btn-sm">{gettext("Got it")}</button>
          </form>
        </div>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button aria-label={gettext("Got it")}>close</button>
      </form>
    </dialog>
    """
  end

  attr :current_user, :any, required: true

  @doc "Asks a user with an unconfirmed email address to confirm it."
  def confirm_email_notice(assigns) do
    ~H"""
    <div
      :if={@current_user && @current_user.email && !Firefly.Moderation.Posting.confirmed_enough?(@current_user)}
      id="confirm-email-notice"
      role="alert"
      class="alert alert-warning"
    >
      <.icon name="hero-envelope" class="size-5" />
      <span>
        {gettext("Confirm your email address to start posting. We sent a link to %{email}.", email: @current_user.email)}
      </span>
      <.form for={%{}} action={~p"/confirm"} method="post">
        <button class="btn btn-sm">{gettext("Resend link")}</button>
      </.form>
    </div>
    """
  end

  attr :current_user, :any, required: true

  @doc "Tells a silenced user what they can't do, why, and until when."
  def silenced_notice(assigns) do
    ~H"""
    <div
      :if={@current_user && Firefly.Accounts.User.silenced?(@current_user)}
      id="silenced-notice"
      role="alert"
      class="alert alert-warning"
    >
      <.icon name="hero-no-symbol" class="size-5" />
      <span>
        {Firefly.Moderation.Posting.message({:silenced, @current_user.silenced_until})}
        {gettext("Reason: %{reason}", reason: @current_user.silence_reason)}
      </span>
    </div>
    """
  end

  @doc """
  The assigns the app layout needs, taken from a LiveView's assigns:

      <Layouts.app {Layouts.shell(assigns)}>...</Layouts.app>
  """
  def shell(assigns) do
    Map.take(assigns, [
      :flash,
      :current_user,
      :notification_count,
      :message_count,
      :review_count,
      :current_path,
      :read_only,
      :update_available,
      :chat,
      :shortcuts,
      :impersonator
    ])
  end

  attr :current_user, :any, required: true

  @doc """
  Tells an admin seeing the site as another member (see
  `FireflyWeb.StaffController`) who they are now, with a way back.
  """
  def impersonation_banner(assigns) do
    ~H"""
    <div id="impersonation-banner" role="alert" class="alert alert-info">
      <.icon name="hero-user-circle" class="size-5" />
      <span>{gettext("You're seeing the site as @%{username}.", username: @current_user.username)}</span>
      <.link href={~p"/impersonate"} method="delete" class="btn btn-sm">
        {gettext("Stop impersonating")}
      </.link>
    </div>
    """
  end

  attr :current_user, :any, required: true
  attr :current_path, :string, default: nil
  attr :review_count, :integer, default: 0
  attr :update_available, :boolean, default: false

  @doc """
  The staff admin's sidebar: back to the forum, a search of the admin, and
  its sections (see `FireflyWeb.StaffNav`), showing the pages the viewer
  may use.
  """
  def staff_nav(assigns) do
    assigns = assign(assigns, :sections, FireflyWeb.StaffNav.sections(assigns.current_user))

    ~H"""
    <nav id="staff-nav" aria-label={gettext("Admin navigation")} class="min-h-full w-64 border-r border-base-300 bg-base-100 p-4">
      <label for="nav-drawer" class="btn btn-ghost btn-sm mb-2 lg:hidden">
        <.icon name="hero-x-mark" class="size-5" /> {gettext("Close menu")}
      </label>
      <.link navigate={~p"/"} class="btn btn-ghost btn-sm mb-2 w-full justify-start">
        <.icon name="hero-arrow-left" class="size-4" /> {gettext("Back to the forum")}
      </.link>
      <form action={~p"/staff"} method="get" role="search" class="mb-2">
        <label class="input input-sm w-full">
          <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
          <input type="search" name="q" placeholder={gettext("Search the admin")} aria-label={gettext("Search the admin")} />
        </label>
      </form>
      <ul class="menu w-full gap-1 p-0">
        <%= for {title, pages} <- @sections do %>
          <li class="menu-title">{title}</li>
          <.nav_item
            :for={page <- pages}
            path={page.path}
            current_path={@current_path}
            icon={page.icon}
            prefix={page.path != "/staff"}
            live={page.live}
          >
            {page.label}
            <span
              :if={page.path == "/staff/review" and @review_count > 0}
              id="review-count"
              class="badge badge-sm badge-warning"
              aria-label={gettext("%{count} to review", count: @review_count)}
            >
              {@review_count}
            </span>
            <span
              :if={page.path == "/staff/upgrade" and @update_available}
              id="update-badge"
              class="badge badge-sm badge-info"
            >
              {gettext("new")}
            </span>
          </.nav_item>
        <% end %>
      </ul>
    </nav>
    """
  end

  attr :path, :string, required: true
  attr :current_path, :string, default: nil
  attr :icon, :string, required: true
  attr :prefix, :boolean, default: false, doc: "also active on the pages under `path`"
  attr :live, :boolean, default: true, doc: "false: a page outside the LiveView session"
  slot :inner_block, required: true

  defp nav_item(assigns) do
    assigns =
      assign(
        assigns,
        :active,
        assigns.current_path == assigns.path or
          (assigns.prefix and String.starts_with?(assigns.current_path || "", assigns.path <> "/"))
      )

    ~H"""
    <li>
      <.link
        {if @live, do: [navigate: @path], else: [href: @path]}
        class={@active && "menu-active"}
        aria-current={@active && "page"}
      >
        <.icon name={@icon} class="size-5" />
        {render_slot(@inner_block)}
      </.link>
    </li>
    """
  end

  @doc """
  The site's logo (the `logo_url` setting; else the Firefly icon, which
  swaps for the dark theme) and title.
  """
  attr :class, :string, default: nil
  attr :size, :string, default: "size-8"

  def logo(assigns) do
    assigns = assign(assigns, :logo_url, Firefly.SiteSettings.get("logo_url"))

    ~H"""
    <span class={["flex items-center gap-2", @class]}>
      <%= if @logo_url != "" do %>
        <img id="site-logo" src={@logo_url} alt="" class={[@size, "w-auto"]} />
      <% else %>
        <img src={~p"/images/firefly-icon.svg"} alt="" class={[@size, "dark:hidden"]} />
        <img src={~p"/images/firefly-icon-dark.svg"} alt="" class={[@size, "hidden dark:block"]} />
      <% end %>
      <span class="text-xl font-bold tracking-tight">{Firefly.SiteSettings.get("title")}</span>
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
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
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
  `FireflyWeb.UserAuth`).
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
        aria-label={gettext("Use system theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={set_theme("light", @persist)}
        data-phx-theme="light"
        aria-label={gettext("Use light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      <button
        class="flex w-1/3 cursor-pointer p-2"
        phx-click={set_theme("dark", @persist)}
        data-phx-theme="dark"
        aria-label={gettext("Use dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
