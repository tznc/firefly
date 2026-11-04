defmodule FireflyWeb.StaffLive.Backups do
  @moduledoc """
  Backups (admins only; see `Firefly.Backups`): make one now, download
  (a short-lived signed link), delete or restore one, and turn read-only
  mode on or off. The running backup's or restore's log shows live.
  Restoring asks for the site's title to confirm. This page keeps
  working while the site is read-only.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Backups, SiteSettings}

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_backups) do
      if connected?(socket), do: Backups.subscribe()
      status = Backups.status()

      {:ok,
       socket
       |> assign(:page_title, "Backups")
       |> assign(:running, status.running)
       |> assign(:log, status.log)
       |> assign(:restoring, nil)
       |> assign(:title, SiteSettings.get("title"))
       |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket) do
    socket
    |> assign(:backups, Backups.list())
    |> assign(:storage, Backups.storage())
    |> assign(:local_uploads?, Backups.local_uploads?())
  end

  @impl true
  def handle_event("create", params, socket) do
    case Backups.create(socket.assigns.current_user, uploads: params["uploads"] == "true") do
      :ok -> {:noreply, socket}
      {:error, :busy} -> {:noreply, put_flash(socket, :error, busy())}
    end
  end

  def handle_event("download", %{"name" => name}, socket) do
    token = Backups.download_token(name, socket.assigns.current_user)
    {:noreply, redirect(socket, to: ~p"/staff/backups/download/#{token}")}
  end

  def handle_event("delete", %{"name" => name}, socket) do
    case Backups.delete(name, socket.assigns.current_user) do
      :ok -> {:noreply, socket |> put_flash(:info, "Backup deleted.") |> load()}
      {:error, message} -> {:noreply, put_flash(socket, :error, "Couldn't delete it: #{message}")}
    end
  end

  def handle_event("confirm_restore", %{"name" => name}, socket),
    do: {:noreply, assign(socket, :restoring, name)}

  def handle_event("cancel_restore", _params, socket),
    do: {:noreply, assign(socket, :restoring, nil)}

  def handle_event("restore", %{"confirmation" => confirmation}, socket) do
    case Backups.restore(socket.assigns.restoring, socket.assigns.current_user, confirmation) do
      :ok -> {:noreply, assign(socket, :restoring, nil)}
      {:error, :busy} -> {:noreply, put_flash(socket, :error, busy())}
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("read_only", %{"on" => on}, socket) do
    reason = if on == "true", do: "maintenance"
    Backups.set_read_only(reason, socket.assigns.current_user)
    {:noreply, socket}
  end

  defp busy, do: "A backup or restore is already running."

  @impl true
  def handle_info({:backup_started, operation}, socket),
    do: {:noreply, socket |> assign(:running, operation) |> assign(:log, [])}

  def handle_info({:backup_log, line}, socket),
    do: {:noreply, assign(socket, :log, socket.assigns.log ++ [line])}

  def handle_info({:backup_finished, _operation, _result}, socket),
    do: {:noreply, socket |> assign(:running, nil) |> load()}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title="Backups" navigate={~p"/staff/backups"}>
        <:subtitle>
          The database{if @local_uploads?, do: " and uploaded files"}, kept {storage_text(@storage)}.
        </:subtitle>
      </.page_header>

      <section class="flex flex-wrap items-center gap-2">
        <button
          id="create-backup"
          phx-click="create"
          phx-value-uploads={to_string(@local_uploads?)}
          class="btn btn-primary btn-sm"
          disabled={@running != nil}
        >
          <.icon name="hero-archive-box-arrow-down" class="size-4" /> Back up now
        </button>
        <button
          :if={@read_only == nil}
          id="read-only-on"
          phx-click="read_only"
          phx-value-on="true"
          class="btn btn-sm"
          data-confirm="Make the forum read-only? Nobody can post until you turn it off."
        >
          <.icon name="hero-lock-closed" class="size-4" /> Make read-only
        </button>
        <button
          :if={@read_only != nil}
          id="read-only-off"
          phx-click="read_only"
          phx-value-on="false"
          class="btn btn-warning btn-sm"
        >
          <.icon name="hero-lock-open" class="size-4" /> Turn off read-only mode
        </button>
        <.link navigate={~p"/staff/settings"} class="link text-sm">Schedule backups in the site settings</.link>
      </section>

      <p :if={not @local_uploads?} class="text-sm text-base-content/70">
        Uploads are stored in S3, which keeps them durably: backups hold just the database.
      </p>

      <section :if={@running || @log != []} id="backup-log" class="space-y-1">
        <h2 class="font-semibold">
          {if @running, do: "#{operation_text(@running)} in progress…", else: "Last run"}
        </h2>
        <pre class="max-h-64 overflow-auto rounded-box bg-base-200 p-3 text-xs"><span :for={line <- @log}>{line}<br /></span></pre>
      </section>

      <p :if={@backups == []} id="backups-empty" class="text-base-content/70">No backups yet.</p>

      <ul :if={@backups != []} id="backups" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
        <li :for={backup <- @backups} id={"backup-#{backup.name}"} class="flex flex-wrap items-center gap-2 p-3">
          <span class="flex-1 break-all font-mono text-sm">{backup.name}</span>
          <span class="text-sm text-base-content/70">{size_text(backup.size)}</span>
          <button phx-click="download" phx-value-name={backup.name} class="btn btn-ghost btn-xs">
            Download
          </button>
          <button
            phx-click="confirm_restore"
            phx-value-name={backup.name}
            class="btn btn-ghost btn-xs"
            disabled={@running != nil}
          >
            Restore
          </button>
          <button
            phx-click="delete"
            phx-value-name={backup.name}
            data-confirm="Delete this backup?"
            class="btn btn-ghost btn-xs text-error"
          >
            Delete
          </button>
        </li>
      </ul>

      <section :if={@restoring} id="restore-form" class="space-y-2 rounded-box border border-error p-4">
        <h2 class="font-semibold">Restore {@restoring}?</h2>
        <p class="text-sm">
          Everything in the database is replaced by the backup's: posts, members and settings made since are lost.
          The forum is read-only while it runs. Type the site's title, <strong>{@title}</strong>, to confirm.
        </p>
        <form phx-submit="restore" class="flex flex-wrap gap-2">
          <input
            type="text"
            name="confirmation"
            autocomplete="off"
            aria-label="Site title"
            class="input input-sm"
          />
          <button class="btn btn-error btn-sm">Restore</button>
          <button type="button" phx-click="cancel_restore" class="btn btn-ghost btn-sm">Cancel</button>
        </form>
      </section>
    </Layouts.app>
    """
  end

  defp storage_text(:s3), do: "in the S3 bucket"
  defp storage_text(_local), do: "on this server"

  defp operation_text(:backup), do: "Backup"
  defp operation_text(:restore), do: "Restore"

  defp size_text(bytes) when bytes >= 1_048_576, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp size_text(bytes), do: "#{Float.round(bytes / 1024, 1)} KB"
end
