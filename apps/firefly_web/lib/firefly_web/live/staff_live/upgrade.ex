defmodule FireflyWeb.StaffLive.Upgrade do
  @moduledoc """
  The upgrade page (admins only; see `Firefly.Upgrades`): the running
  version against the latest release (with its notes), a "check now"
  button, the database migrations the running code hasn't applied, and
  the steps of an upgrade for Docker and for a release. Firefly doesn't
  upgrade itself: admins run the steps.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Upgrades

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_upgrades) do
      {:ok,
       socket
       |> assign(:page_title, "Upgrade")
       |> assign(:status, Upgrades.status())
       |> assign(:pending, Upgrades.pending_migrations())
       |> assign(:repo, Upgrades.repo())}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("check", _params, socket) do
    case Upgrades.check() do
      {:ok, status} ->
        {:noreply, socket |> assign(:status, status) |> put_flash(:info, "Checked.")}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:status, Upgrades.status())
         |> put_flash(:error, "Couldn't check: #{message}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title="Upgrade" navigate={~p"/staff/upgrade"}>
        <:subtitle>Keep Firefly up to date.</:subtitle>
      </.page_header>

      <FireflyWeb.UpgradeComponents.version_status status={@status} repo={@repo} />

      <button id="check-now" phx-click="check" class="btn btn-sm">
        <.icon name="hero-arrow-path" class="size-4" /> Check now
      </button>

      <section :if={@status.update? and @status.notes_html != ""} id="release-notes" class="space-y-2">
        <h2 class="text-lg font-semibold">What's new in {@status.name || @status.latest}</h2>
        <div class="prose prose-sm max-w-none rounded-box border border-base-300 bg-base-100 p-4">
          {Phoenix.HTML.raw(@status.notes_html)}
        </div>
        <a :if={@status.url} href={@status.url} class="link text-sm" rel="noopener noreferrer" target="_blank">
          The release on GitHub
        </a>
      </section>

      <section id="pending-migrations" class="space-y-2">
        <h2 class="text-lg font-semibold">Database migrations</h2>
        <p :if={@pending == []} class="text-sm text-base-content/70">
          The database is up to date with the running code.
        </p>
        <div :if={@pending != []} class="space-y-2">
          <p class="alert alert-warning text-sm">
            {length(@pending)} migrations of the running code haven't run. Run them (step 3 below).
          </p>
          <ul class="font-mono text-xs">
            <li :for={{version, name} <- @pending}>{version} {name}</li>
          </ul>
        </div>
      </section>

      <section id="steps-docker" class="space-y-2">
        <h2 class="text-lg font-semibold">Upgrading with Docker</h2>
        <ol class="list-decimal space-y-2 pl-6 text-sm">
          <li>
            <.link navigate={~p"/staff/backups"} class="link">Make a backup</.link>
            and download it, in case you need to go back.
          </li>
          <li>
            Get the new image: <code>docker pull &lt;your image&gt;:{@status.latest || "<tag>"}</code>
            from your registry, or build it from the release:
            <code>git checkout {@status.latest || "<tag>"} && docker build -t firefly --build-arg FIREFLY_GIT_SHA=$(git rev-parse HEAD) .</code>
          </li>
          <li>
            Run the migrations with the new image:
            <code>docker run --rm --env-file .env firefly /app/bin/firefly eval Firefly.Release.migrate</code>
          </li>
          <li>
            Restart with the new image: <code>docker compose up -d</code>
            (or stop the old container and <code>docker run</code> the new one).
          </li>
        </ol>
      </section>

      <section id="steps-release" class="space-y-2">
        <h2 class="text-lg font-semibold">Upgrading a release</h2>
        <ol class="list-decimal space-y-2 pl-6 text-sm">
          <li>
            <.link navigate={~p"/staff/backups"} class="link">Make a backup</.link>
            and download it.
          </li>
          <li>
            Check out the new version and build it:
            <code>git fetch --tags && git checkout {@status.latest || "<tag>"}</code>,
            then <code>MIX_ENV=prod mix do deps.get, assets.deploy, release</code>.
          </li>
          <li>Run the migrations: <code>_build/prod/rel/firefly/bin/firefly eval Firefly.Release.migrate</code></li>
          <li>Restart: <code>_build/prod/rel/firefly/bin/firefly restart</code> (or restart its service).</li>
        </ol>
      </section>
    </Layouts.app>
    """
  end
end
