defmodule FireflyWeb.StaffLive.Badges do
  @moduledoc """
  Badges (admins only): create custom badges, edit them (system badges:
  only whether they're enabled, listed and usable as a title) and delete
  custom ones. Granting and revoking happen on each badge's page. See
  `Firefly.Badges`.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Badges
  alias Firefly.Forums.Badge

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_badges) do
      {:ok,
       socket
       |> assign(:page_title, "Badges")
       |> assign(:editing, nil)
       |> assign(:form, to_form(Badges.change_badge(%Badge{})))
       |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket), do: assign(socket, :badges, Badges.list_badges())

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    badge = Badges.get_badge!(id)

    {:noreply,
     socket |> assign(:editing, badge) |> assign(:form, to_form(Badges.change_badge(badge)))}
  end

  def handle_event("new", _params, socket) do
    {:noreply,
     socket |> assign(:editing, nil) |> assign(:form, to_form(Badges.change_badge(%Badge{})))}
  end

  def handle_event("save", %{"badge" => params}, socket) do
    admin = socket.assigns.current_user

    result =
      case socket.assigns.editing do
        nil -> Badges.create_badge(params, admin)
        badge -> Badges.update_badge(badge, params, admin)
      end

    case result do
      {:ok, badge} ->
        {:noreply,
         socket
         |> put_flash(:info, "Saved #{badge.name}.")
         |> assign(:editing, nil)
         |> assign(:form, to_form(Badges.change_badge(%Badge{})))
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Badges.delete_badge(Badges.get_badge!(id), socket.assigns.current_user) do
      {:ok, badge} -> {:noreply, socket |> put_flash(:info, "Deleted #{badge.name}.") |> load()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Badges.message(reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Badges" navigate={~p"/staff/badges"}>
        <:subtitle>
          System badges are granted automatically; grant custom ones from their
          <.link navigate={~p"/badges"} class="link">badge pages</.link>.
        </:subtitle>
      </.page_header>

      <.form
        for={@form}
        id="badge-form"
        phx-submit="save"
        class="card border border-base-300 bg-base-100"
      >
        <div class="card-body gap-2">
          <h2 class="card-title">
            {if @editing, do: "Edit #{@editing.name}", else: "New badge"}
          </h2>
          <div :if={!(@editing && @editing.system)} class="grid gap-2 sm:grid-cols-2">
            <.input field={@form[:name]} type="text" label="Name" />
            <.input field={@form[:icon]} type="select" label="Icon" options={Badge.icons()} />
            <.input
              field={@form[:badge_type]}
              type="select"
              label="Type"
              options={Enum.map(Badge.types(), &{String.capitalize(&1), &1})}
            />
            <.input
              field={@form[:grouping]}
              type="select"
              label="Grouping"
              options={Enum.map(Badge.groupings(), &{Badge.grouping_label(&1), &1})}
            />
            <div class="sm:col-span-2">
              <.input field={@form[:description]} type="textarea" label="Description" rows="2" />
            </div>
            <.input
              field={@form[:multiple_grant]}
              type="checkbox"
              label="Can be granted more than once"
            />
          </div>
          <div class="flex flex-wrap gap-4">
            <.input field={@form[:enabled]} type="checkbox" label="Enabled" />
            <.input field={@form[:listable]} type="checkbox" label="Listed on the badges page" />
            <.input field={@form[:allow_title]} type="checkbox" label="Can be used as a title" />
          </div>
          <div class="flex justify-end gap-2">
            <button :if={@editing} type="button" phx-click="new" class="btn btn-ghost">Cancel</button>
            <.button variant="primary" phx-disable-with="Saving...">Save badge</.button>
          </div>
        </div>
      </.form>

      <ul id="staff-badges" class="list rounded-box border border-base-300 bg-base-100">
        <li :for={badge <- @badges} id={"staff-badge-#{badge.id}"} class="list-row items-center">
          <.badge_icon badge={badge} />
          <div class="list-col-grow">
            <.link navigate={~p"/badges/#{badge.id}"} class="font-semibold hover:text-primary">
              {badge.name}
            </.link>
            <span :if={badge.system} class="badge badge-ghost badge-xs">System</span>
            <span :if={!badge.enabled} class="badge badge-warning badge-xs">Disabled</span>
            <span class="block text-sm text-base-content/70">{badge.description}</span>
          </div>
          <button phx-click="edit" phx-value-id={badge.id} class="btn btn-ghost btn-xs">Edit</button>
          <button
            :if={!badge.system}
            phx-click="delete"
            phx-value-id={badge.id}
            data-confirm={"Delete #{badge.name}? Everyone who has it loses it."}
            class="btn btn-ghost btn-xs text-error"
          >
            Delete
          </button>
        </li>
      </ul>
    </Layouts.app>
    """
  end
end
