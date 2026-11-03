defmodule FireflyWeb.StaffLive.Index do
  @moduledoc """
  The staff admin's home (`/staff`, staff only): what needs attention
  (accounts waiting for approval, the review queue, emails that failed
  today), every admin page the viewer may use by section (see
  `FireflyWeb.StaffNav`), and a search across the admin's pages and site
  settings (`?q=`, also from the admin sidebar's search box).
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Moderation, SiteSettings}
  alias Firefly.Accounts.UserAdmin
  alias Firefly.Notifications.EmailLog
  alias FireflyWeb.StaffNav

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if can?(user, :view_admin) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Admin"))
       |> assign(:sections, StaffNav.sections(user))
       |> assign(:pending, if(can?(user, :approve_user), do: UserAdmin.pending_count(), else: 0))
       |> assign(:pending_review, Moderation.Review.pending_count())
       |> assign(
         :failed_emails,
         if(can?(user, :manage_emails), do: EmailLog.last_day_counts()["failed"], else: 0)
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    q = String.trim(params["q"] || "")
    user = socket.assigns.current_user

    {:noreply,
     socket
     |> assign(:q, q)
     |> assign(:pages, if(q == "", do: [], else: StaffNav.search(user, q)))
     |> assign(
       :settings,
       if(q != "" and can?(user, :manage_site_settings), do: matching_settings(q), else: [])
     )}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/staff?#{%{q: q}}")}
  end

  # Settings whose key, label, help or section mention every word.
  defp matching_settings(q) do
    words = q |> String.downcase() |> String.split(~r/\s+/, trim: true)

    SiteSettings.definitions()
    |> Enum.filter(fn definition ->
      text =
        String.downcase(
          Enum.join([definition.key, definition.label, definition.help, definition.section], " ")
        )

      Enum.all?(words, &String.contains?(text, &1))
    end)
    |> Enum.take(20)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title={gettext("Admin")} navigate={~p"/staff"}>
        <:subtitle>{gettext("Everything staff run the forum with, in one place.")}</:subtitle>
      </.page_header>

      <form id="admin-search" phx-change="search" phx-submit="search" role="search">
        <label class="input w-full">
          <.icon name="hero-magnifying-glass" class="size-5 opacity-60" />
          <input
            type="search"
            name="q"
            value={@q}
            phx-debounce="200"
            placeholder={gettext("Search admin pages and settings")}
            aria-label={gettext("Search admin pages and settings")}
          />
        </label>
      </form>

      <section :if={@q != ""} id="admin-search-results" class="space-y-3" aria-live="polite">
        <h2 class="text-lg font-semibold">{gettext("Results for “%{q}”", q: @q)}</h2>
        <p :if={@pages == [] and @settings == []} class="text-base-content/70">
          {gettext("Nothing matches. Try another word.")}
        </p>
        <ul :if={@pages != []} id="admin-search-pages" class="list rounded-box border border-base-300 bg-base-100">
          <li :for={page <- @pages} class="list-row items-center">
            <.icon name={page.icon} class="size-5 opacity-70" />
            <div>
              <.link navigate={page.path} class="link font-medium">{page.label}</.link>
              <p class="text-xs text-base-content/70">{page.section}</p>
            </div>
          </li>
        </ul>
        <ul :if={@settings != []} id="admin-search-settings" class="list rounded-box border border-base-300 bg-base-100">
          <li :for={setting <- @settings} class="list-row">
            <div>
              <.link navigate={~p"/staff/settings?#{%{q: setting.key}}"} class="link font-medium">
                {setting.label}
              </.link>
              <p class="text-xs text-base-content/70">{gettext("Site setting")} · {setting.section}</p>
              <p class="text-sm text-base-content/80">{setting.help}</p>
            </div>
          </li>
        </ul>
      </section>

      <section id="admin-attention" class="grid gap-4 sm:grid-cols-3">
        <.link :if={can?(@current_user, :approve_user)} navigate={~p"/staff/users?filter=pending"} class="card border border-base-300 bg-base-100 hover:border-primary">
          <div class="card-body gap-1">
            <span class="text-sm text-base-content/70">{gettext("Waiting for approval")}</span>
            <span id="attention-pending" class="text-2xl font-bold">{@pending}</span>
          </div>
        </.link>
        <.link :if={can?(@current_user, :review)} navigate={~p"/staff/review"} class="card border border-base-300 bg-base-100 hover:border-primary">
          <div class="card-body gap-1">
            <span class="text-sm text-base-content/70">{gettext("In the review queue")}</span>
            <span id="attention-review" class="text-2xl font-bold">{@pending_review}</span>
          </div>
        </.link>
        <.link :if={can?(@current_user, :manage_emails)} navigate={~p"/staff/emails?status=failed"} class="card border border-base-300 bg-base-100 hover:border-primary">
          <div class="card-body gap-1">
            <span class="text-sm text-base-content/70">{gettext("Emails failed today")}</span>
            <span id="attention-emails" class="text-2xl font-bold">{@failed_emails}</span>
          </div>
        </.link>
      </section>

      <section :for={{title, pages} <- @sections} class="space-y-2">
        <h2 class="text-lg font-semibold">{title}</h2>
        <ul class="grid gap-2 sm:grid-cols-2">
          <li :for={page <- pages}>
            <.link navigate={page.path} class="flex items-center gap-2 rounded-box border border-base-300 bg-base-100 p-3 hover:border-primary">
              <.icon name={page.icon} class="size-5 opacity-70" />
              <span>{page.label}</span>
            </.link>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
