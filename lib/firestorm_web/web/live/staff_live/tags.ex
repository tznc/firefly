defmodule FirestormWeb.Web.StaffLive.Tags do
  @moduledoc """
  Tag groups and synonyms (admins only; see `FirestormWeb.Tags`): create,
  edit and delete groups and the tags in them, and make tags synonyms of
  others.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Repo, Tags}
  alias FirestormWeb.Forums.Tag

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_tags) do
      {:ok,
       socket
       |> assign(:page_title, "Tags")
       |> assign(:new_form, to_form(Tags.change_group(), as: :group))
       |> assign(:synonym_form, to_form(%{}, as: :synonym))
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
    |> assign(:groups, Tags.list_groups())
    |> assign(:synonyms, Tags.list_synonyms())
  end

  @impl true
  def handle_event(event, params, socket) do
    if can?(socket.assigns.current_user, :manage_tags),
      do: tags_event(event, params, socket),
      else: {:noreply, put_flash(socket, :error, denied_message(socket.assigns.current_user))}
  end

  defp tags_event("create_group", %{"group" => params}, socket) do
    case Tags.create_group(params, socket.assigns.current_user) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tag group #{group.name} created.")
         |> assign(:new_form, to_form(Tags.change_group(), as: :group))
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :new_form, to_form(changeset, as: :group, action: :validate))}
    end
  end

  defp tags_event("update_group", %{"group_id" => id, "group" => params}, socket) do
    case Tags.update_group(Tags.get_group!(id), params, socket.assigns.current_user) do
      {:ok, group} ->
        {:noreply, socket |> put_flash(:info, "Tag group #{group.name} saved.") |> load()}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Couldn't save the group: #{error_text(changeset)}")}
    end
  end

  defp tags_event("delete_group", %{"id" => id}, socket) do
    {:ok, group} = Tags.delete_group(Tags.get_group!(id), socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Tag group #{group.name} deleted.") |> load()}
  end

  defp tags_event("make_synonym", %{"synonym" => params}, socket) do
    case Tags.make_synonym(params["name"], params["canonical"], socket.assigns.current_user) do
      {:ok, synonym} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{synonym.name} is now a synonym of #{params["canonical"]}.")
         |> assign(:synonym_form, to_form(%{}, as: :synonym))
         |> load()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, Tags.message(reason))
         |> assign(:synonym_form, to_form(params, as: :synonym))}
    end
  end

  defp tags_event("remove_synonym", %{"id" => id}, socket) do
    {:ok, tag} = Tags.remove_synonym(Repo.get!(Tag, id), socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "#{tag.name} is a tag of its own again.") |> load()}
  end

  defp error_text(changeset) do
    Enum.map_join(changeset.errors, "; ", fn {field, error} ->
      "#{field} #{translate_error(error)}"
    end)
  end

  defp tag_names(group), do: Enum.map_join(group.tags, ", ", & &1.name)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Tag groups and synonyms" navigate={~p"/staff/tags"}>
        <:subtitle>Changes apply at once and are recorded in the staff log.</:subtitle>
      </.page_header>

      <section id="new-tag-group" class="card border border-base-300 bg-base-100">
        <.form for={@new_form} id="new-tag-group-form" phx-submit="create_group" class="card-body gap-2">
          <h2 class="card-title">New group</h2>
          <.input field={@new_form[:name]} label="Name" />
          <.input
            id="new-group-tags"
            name="group[tags]"
            value={@new_form.params["tags"]}
            label="Tags"
            placeholder="e.g. bug, feature, question"
          />
          <.input field={@new_form[:staff_only]} type="checkbox" label="Only staff can use these tags" />
          <.input field={@new_form[:one_per_thread]} type="checkbox" label="At most one of these tags per thread" />
          <div><.button variant="primary">Create group</.button></div>
        </.form>
      </section>

      <section
        :for={group <- @groups}
        id={"tag-group-#{group.id}"}
        class="card border border-base-300 bg-base-100"
      >
        <form id={"tag-group-form-#{group.id}"} phx-submit="update_group" class="card-body gap-2">
          <h2 class="card-title">
            {group.name}
            <span :if={group.staff_only} class="badge badge-warning badge-sm">staff only</span>
            <span :if={group.one_per_thread} class="badge badge-ghost badge-sm">one per thread</span>
          </h2>
          <input type="hidden" name="group_id" value={group.id} />
          <.input id={"group-#{group.id}-name"} name="group[name]" value={group.name} label="Name" />
          <.input id={"group-#{group.id}-tags"} name="group[tags]" value={tag_names(group)} label="Tags" />
          <.input
            id={"group-#{group.id}-staff-only"}
            name="group[staff_only]"
            type="checkbox"
            checked={group.staff_only}
            label="Only staff can use these tags"
          />
          <.input
            id={"group-#{group.id}-one-per-thread"}
            name="group[one_per_thread]"
            type="checkbox"
            checked={group.one_per_thread}
            label="At most one of these tags per thread"
          />
          <div class="flex gap-2">
            <.button>Save</.button>
            <button
              type="button"
              phx-click="delete_group"
              phx-value-id={group.id}
              data-confirm={"Delete the #{group.name} group? Its tags stay."}
              class="btn btn-ghost text-error"
            >
              Delete
            </button>
          </div>
        </form>
      </section>

      <section id="synonyms" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-2">
          <h2 class="card-title">Synonyms</h2>
          <p class="text-sm text-base-content/70">
            A synonym is stored as its canonical tag: its threads move there now, and it's applied as the canonical tag from then on.
          </p>
          <.form
            for={@synonym_form}
            id="synonym-form"
            phx-submit="make_synonym"
            class="flex flex-wrap items-end gap-2"
          >
            <.input field={@synonym_form[:name]} label="Make the tag" />
            <.input field={@synonym_form[:canonical]} label="a synonym of" />
            <.button>Save</.button>
          </.form>
          <ul class="space-y-1">
            <li :for={tag <- @synonyms} id={"synonym-#{tag.id}"} class="flex items-center gap-2">
              <span>{tag.name} → <.link navigate={~p"/tags/#{tag.synonym_of.name}"} class="link">{tag.synonym_of.name}</.link></span>
              <button phx-click="remove_synonym" phx-value-id={tag.id} class="btn btn-ghost btn-xs">
                Remove
              </button>
            </li>
          </ul>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
