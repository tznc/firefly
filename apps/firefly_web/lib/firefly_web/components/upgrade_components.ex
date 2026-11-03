defmodule FireflyWeb.UpgradeComponents do
  @moduledoc "The running and latest versions (see `Firefly.Upgrades`), on the dashboard and upgrade page."
  use FireflyWeb, :html

  attr :status, :map, required: true, doc: "`Firefly.Upgrades.status/0`"
  attr :repo, :string, required: true

  def version_status(assigns) do
    ~H"""
    <section id="version" class="space-y-1 rounded-box border border-base-300 bg-base-100 p-4 text-sm">
      <div>
        Running <strong>Firefly {@status.current}</strong>
        <span :if={@status.git_sha} class="font-mono text-xs text-base-content/70">
          ({String.slice(@status.git_sha, 0, 12)})
        </span>
      </div>
      <div :if={@status.update?} id="update-available" class="alert alert-info">
        <.icon name="hero-arrow-up-circle" class="size-5" />
        <span>
          A new version is available: <strong>{@status.latest}</strong>.
          <.link navigate={~p"/staff/upgrade"} class="link">How to upgrade</.link>
        </span>
      </div>
      <div :if={!@status.update? and @status.latest} class="text-base-content/70">
        Up to date (the latest release is {@status.latest}).
      </div>
      <div :if={@status.checked_at} class="text-xs text-base-content/70">
        Last checked {@status.checked_at} against github.com/{@repo}.
        <span :if={@status.error} class="text-error">The check failed: {@status.error}</span>
      </div>
    </section>
    """
  end
end
