defmodule FireflyWeb.StaffLive.Embedding do
  @moduledoc """
  Embedding (admins only; see `Firefly.Embedding`): the sites allowed to
  embed topics as comments, a form to add one, and the snippet sites
  include. Who posts the topics and the feed to poll are site settings.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Discussion, Embedding}

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_embedding) do
      {:ok,
       socket
       |> assign(:page_title, "Embedding")
       |> assign(:categories, Discussion.list_categories(socket.assigns.current_user))
       |> assign(:form, to_form(Embedding.change_host()))
       |> assign(:hosts, Embedding.list_hosts())}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_event("save", %{"embeddable_host" => params}, socket) do
    params =
      Map.update(params, "allowed_paths", [], &String.split(&1 || "", ~r/[\s,]+/, trim: true))

    case Embedding.create_host(params, socket.assigns.current_user) do
      {:ok, _host} ->
        {:noreply,
         socket
         |> put_flash(:info, "Host added.")
         |> assign(:form, to_form(Embedding.change_host()))
         |> assign(:hosts, Embedding.list_hosts())}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    if host = Embedding.get_host(id), do: Embedding.delete_host(host, socket.assigns.current_user)

    {:noreply,
     socket |> put_flash(:info, "Host removed.") |> assign(:hosts, Embedding.list_hosts())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title="Embedding" navigate={~p"/staff/embedding"}>
        <:subtitle>Use topics as the comments of blog posts and other pages.</:subtitle>
      </.page_header>

      <p :if={@hosts == []} id="hosts-empty" class="text-base-content/70">No sites can embed yet.</p>

      <ul :if={@hosts != []} id="hosts" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
        <li :for={host <- @hosts} id={"host-#{host.id}"} class="flex flex-wrap items-center gap-2 p-3">
          <span class="flex-1 font-medium">{host.host}</span>
          <span :if={host.allowed_paths != []} class="text-sm text-base-content/70">
            {Enum.join(host.allowed_paths, ", ")}
          </span>
          <span :if={host.category} class="badge badge-sm">{host.category.title}</span>
          <span :if={host.tag} class="badge badge-ghost badge-sm">#{host.tag}</span>
          <button
            phx-click="delete"
            phx-value-id={host.id}
            data-confirm={"Stop #{host.host} embedding topics?"}
            class="btn btn-ghost btn-xs text-error"
          >
            Remove
          </button>
        </li>
      </ul>

      <.form for={@form} id="host-form" phx-submit="save" class="space-y-2 rounded-box border border-base-300 p-4">
        <h2 class="font-semibold">Add a site</h2>
        <.input field={@form[:host]} label="Host" placeholder="blog.example.com" />
        <.input
          name={@form[:allowed_paths].name}
          value={Enum.join(@form[:allowed_paths].value || [], " ")}
          label="Paths (optional: pages must start with one, e.g. /posts/)"
        />
        <.input
          field={@form[:category_id]}
          type="select"
          label="Category for its topics"
          prompt="The first category"
          options={Enum.map(@categories, &{&1.title, &1.id})}
        />
        <.input field={@form[:tag]} label="Tag for its topics (optional)" />
        <.input field={@form[:class_name]} label="CSS class for the comments page (optional)" />
        <button class="btn btn-primary btn-sm">Add site</button>
      </.form>

      <section id="snippet" class="space-y-2">
        <h2 class="font-semibold">On the site's pages</h2>
        <p class="text-sm">
          Put this where the comments go. Each page gets its topic the first time it's viewed,
          posted as set in <.link navigate={~p"/staff/settings"} class="link">the site settings</.link> (Embedding).
        </p>
        <pre class="overflow-x-auto rounded-box bg-base-200 p-3 text-xs"><code>{snippet()}</code></pre>
      </section>
    </Layouts.app>
    """
  end

  defp snippet do
    """
    <div id="firefly-comments"></div>
    <script>
      window.FireflyEmbed = {
        fireflyUrl: "#{Firefly.Endpoint.url()}",
        embedUrl: window.location.href.split("#")[0]
        // or topicId: 123, to show an existing topic
      };
      (function () {
        var s = document.createElement("script");
        s.src = window.FireflyEmbed.fireflyUrl + "/embed.js";
        s.async = true;
        document.head.appendChild(s);
      })();
    </script>\
    """
  end
end
