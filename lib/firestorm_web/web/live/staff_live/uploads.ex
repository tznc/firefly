defmodule FirestormWeb.Web.StaffLive.Uploads do
  @moduledoc """
  Every upload (admins only), newest first: who uploaded it, its size and
  type, and what it's attached to. Admins can delete one (e.g. a file that
  mustn't be hosted); that's recorded in the staff log. See
  `FirestormWeb.Uploads`.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Repo, Uploads}
  alias FirestormWeb.Uploads.Upload

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_uploads) do
      {:ok, assign(socket, :page_title, "Uploads")}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket),
    do: {:noreply, assign(socket, :page, Uploads.list(params["page"]))}

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case Repo.get(Upload, id) do
      nil ->
        {:noreply, socket}

      upload ->
        :ok = Uploads.delete(upload, socket.assigns.current_user)

        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{upload.filename}.")
         |> assign(:page, Uploads.list(socket.assigns.page.page_number))}
    end
  end

  defp attachment(%Upload{attached_to: "post", post_id: id}) when is_integer(id),
    do: "Post ##{id}"

  defp attachment(%Upload{attached_to: "message"}), do: "Private message"
  defp attachment(%Upload{attached_to: "avatar"}), do: "Avatar"
  defp attachment(%Upload{}), do: "Unused"

  defp size(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp size(bytes), do: "#{Float.round(bytes / (1024 * 1024), 1)} MB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Uploads" navigate={~p"/staff/uploads"}>
        <:subtitle>Files members uploaded, newest first.</:subtitle>
      </.page_header>

      <p :if={@page.entries == []} id="uploads-empty" class="text-base-content/70">
        No uploads yet.
      </p>

      <div :if={@page.entries != []} class="overflow-x-auto">
        <table id="uploads" class="table">
          <thead>
            <tr>
              <th>File</th>
              <th>Uploader</th>
              <th>Size</th>
              <th>Attached to</th>
              <th>When</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={upload <- @page.entries} id={"upload-#{upload.id}"}>
              <td class="max-w-xs truncate">
                <a href={Uploads.url(upload)} class="link" target="_blank" rel="noopener">
                  {upload.filename}
                </a>
                <span class="text-xs text-base-content/60">{upload.content_type}</span>
              </td>
              <td>
                <.link :if={upload.user} navigate={~p"/users/#{upload.user}"} class="link">
                  {upload.user.username}
                </.link>
              </td>
              <td class="whitespace-nowrap">{size(upload.size)}</td>
              <td>{attachment(upload)}</td>
              <td class="whitespace-nowrap text-sm">
                <.time_ago at={upload.inserted_at} id={"upload-#{upload.id}-at"} />
              </td>
              <td>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="delete"
                  phx-value-id={upload.id}
                  data-confirm={"Delete #{upload.filename}? Posts using it will show a broken link."}
                  aria-label={"Delete #{upload.filename}"}
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.pagination page={@page} path={~p"/staff/uploads"} />
    </Layouts.app>
    """
  end
end
