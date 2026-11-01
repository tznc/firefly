defmodule FirestormWeb.Web.CategoryLive.Form do
  @moduledoc "Creates or edits a category."
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.Category

  @impl true
  def mount(params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_category) do
      {:ok, apply_action(socket, socket.assigns.live_action, params)}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/categories")}
    end
  end

  defp apply_action(socket, :new, _params) do
    category = %Category{}

    socket
    |> assign(:page_title, "New Category")
    |> assign(:category, category)
    |> assign(:form, to_form(Forums.change_category(category)))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    category = Forums.get_category!(id)

    socket
    |> assign(:page_title, "Edit #{category.title}")
    |> assign(:category, category)
    |> assign(:form, to_form(Forums.change_category(category)))
  end

  @impl true
  def handle_event("validate", %{"category" => params}, socket) do
    changeset = Category.changeset(socket.assigns.category, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"category" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case Forums.create_category(params) do
      {:ok, category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category created successfully.")
         |> push_navigate(to: ~p"/categories/#{category}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save(socket, :edit, params) do
    case Forums.update_category(socket.assigns.category, params) do
      {:ok, category} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category updated successfully.")
         |> push_navigate(to: ~p"/categories/#{category}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title={
        if @live_action == :new, do: "Create a new category", else: "Edit Category"
      } />

      <.form for={@form} id="category-form" phx-change="validate" phx-submit="save" class="space-y-4">
        <.input field={@form[:title]} type="text" label="Title" placeholder="Type a title" />
        <div class="flex justify-end gap-2">
          <.link navigate={~p"/categories"} class="btn btn-ghost">Cancel</.link>
          <.button variant="primary" phx-disable-with="Saving...">
            {if @live_action == :new, do: "Create Category", else: "Save Category"}
          </.button>
        </div>
      </.form>
    </Layouts.app>
    """
  end
end
