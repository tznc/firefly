defmodule FirestormWeb.Web.StaffLive.Emoji do
  @moduledoc """
  Custom emoji (admins only): add one with a name and an image (uploaded
  through `FirestormWeb.Uploads`), or remove one. See `FirestormWeb.Emoji`.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Emoji, Repo, Uploads}
  alias FirestormWeb.Emoji.CustomEmoji

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_emoji) do
      {:ok,
       socket
       |> assign(:page_title, "Emoji")
       |> assign(:emoji, Emoji.list())
       |> assign(:form, to_form(Emoji.change_emoji()))
       |> allow_upload(:image,
         accept: ~w(.png .jpg .jpeg .gif .webp),
         max_entries: 1,
         max_file_size: Uploads.max_size()
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("validate", %{"custom_emoji" => params}, socket) do
    changeset = Emoji.change_emoji(params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"custom_emoji" => params}, socket) do
    admin = socket.assigns.current_user

    result =
      case uploaded_entries(socket, :image) do
        {[_entry], []} ->
          [result] =
            consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
              {:ok, Emoji.create(admin, params, path, entry.client_name)}
            end)

          result

        _none ->
          {:error, "Pick an image for the emoji."}
      end

    case result do
      {:ok, emoji} ->
        {:noreply,
         socket
         |> put_flash(:info, "Added :#{emoji.name}:.")
         |> assign(:emoji, Emoji.list())
         |> assign(:form, to_form(Emoji.change_emoji()))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Repo.get(CustomEmoji, id) do
      nil ->
        {:noreply, socket}

      emoji ->
        :ok = Emoji.delete(emoji, socket.assigns.current_user)

        {:noreply,
         socket
         |> put_flash(:info, "Removed :#{emoji.name}:.")
         |> assign(:emoji, Emoji.list())}
    end
  end

  defp upload_error(:too_large), do: "That file is too large."
  defp upload_error(:not_accepted), do: "Pick a PNG, JPEG, GIF or WebP image."
  defp upload_error(:too_many_files), do: "Pick one image."
  defp upload_error(other), do: "Upload error: #{other}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Emoji" navigate={~p"/staff/emoji"}>
        <:subtitle>Custom emoji members can use as <code>:name:</code> in posts.</:subtitle>
      </.page_header>

      <.form
        for={@form}
        id="emoji-form"
        phx-change="validate"
        phx-submit="save"
        class="card border border-base-300 bg-base-100"
      >
        <div class="card-body gap-2">
          <h2 class="card-title">Add an emoji</h2>
          <.input field={@form[:name]} type="text" label="Name" placeholder="party_parrot" />
          <label class="text-sm font-medium" for={@uploads.image.ref}>Image</label>
          <.live_file_input upload={@uploads.image} class="file-input" />
          <p
            :for={err <- upload_errors(@uploads.image) ++ Enum.flat_map(@uploads.image.entries, &upload_errors(@uploads.image, &1))}
            class="text-sm text-error"
          >
            {upload_error(err)}
          </p>
          <div class="flex justify-end">
            <.button variant="primary" phx-disable-with="Adding...">Add emoji</.button>
          </div>
        </div>
      </.form>

      <p :if={@emoji == []} id="emoji-empty" class="text-base-content/70">No custom emoji yet.</p>

      <ul :if={@emoji != []} id="custom-emoji" class="grid gap-2 sm:grid-cols-2">
        <li
          :for={emoji <- @emoji}
          id={"emoji-#{emoji.id}"}
          class="flex items-center gap-3 rounded-box border border-base-300 bg-base-100 p-3"
        >
          <img src={Uploads.url(emoji.upload)} alt={":#{emoji.name}:"} class="size-8 object-contain" />
          <code class="flex-1">:{emoji.name}:</code>
          <button
            type="button"
            class="btn btn-ghost btn-xs text-error"
            phx-click="delete"
            phx-value-id={emoji.id}
            data-confirm={"Remove :#{emoji.name}:? Posts using it will show the name instead."}
            aria-label={"Remove :#{emoji.name}:"}
          >
            Remove
          </button>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
