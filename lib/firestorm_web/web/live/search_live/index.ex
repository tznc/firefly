defmodule FirestormWeb.Web.SearchLive.Index do
  @moduledoc """
  Full-text search (see `FirestormWeb.Search`). The query and filters live in
  the URL (`/search?q=...&category=...`), so results can be linked and paged.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{Forums, Search}

  @controls ~w(category tag user in order)

  @impl true
  def mount(_params, _session, socket) do
    categories =
      Enum.map(Forums.list_categories(socket.assigns.current_user), &{&1.title, &1.slug})

    {:ok, assign(socket, page_title: "Search", categories: categories)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = Map.take(params, ["q" | @controls])
    search = Search.parse(params["q"], query)
    page = Search.run(search, socket.assigns.current_user, params["page"] || 1)

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:searched?, Search.present?(search))
     |> assign(:form, to_form(query, as: :search))
     |> assign(:results, page)}
  end

  @impl true
  def handle_event("search", %{"search" => params}, socket) do
    query = params |> Map.take(["q" | @controls]) |> Map.reject(fn {_k, v} -> v in ["", nil] end)
    {:noreply, push_patch(socket, to: ~p"/search?#{query}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Search" />

      <.form for={@form} id="search-form" phx-submit="search" class="space-y-3">
        <div class="join w-full">
          <input
            type="search"
            name="search[q]"
            value={@form[:q].value}
            placeholder="Search posts, e.g. supervisor tag:otp @alice"
            aria-label="Search terms"
            class="input join-item w-full"
          />
          <button type="submit" class="btn btn-primary join-item">
            <.icon name="hero-magnifying-glass" class="size-4" /> Search
          </button>
        </div>
        <div class="grid gap-x-3 sm:grid-cols-3">
          <.input
            field={@form[:category]}
            type="select"
            label="Category"
            prompt="Any category"
            options={@categories}
          />
          <.input field={@form[:tag]} type="text" label="Tag" placeholder="Any tag" />
          <.input field={@form[:user]} type="text" label="Posted by" placeholder="Anyone" />
          <.input
            field={@form[:order]}
            type="select"
            label="Sort by"
            options={[{"Relevance", "relevance"}, {"Latest", "latest"}]}
          />
          <label class="label self-end pb-3 text-sm">
            <input
              type="checkbox"
              name="search[in]"
              value="title"
              checked={@form[:in].value == "title"}
              class="checkbox checkbox-sm"
            /> Titles only
          </label>
        </div>
        <p class="text-xs text-base-content/60">
          Also in the search box: <code>category:slug</code>, <code>tag:name</code>,
          <code>@username</code>, <code>in:title</code>, <code>order:latest</code>, <code>"exact phrase"</code>, <code>-exclude</code>.
        </p>
      </.form>

      <section :if={@searched?} id="search-results" class="space-y-4">
        <p class="text-sm text-base-content/70">
          {ngettext("1 result", "%{count} results", @results.total_entries)}
        </p>
        <ol class="list rounded-box border border-base-300 bg-base-100">
          <li
            :for={%{post: post, thread: thread, headline: headline} <- @results.entries}
            id={"result-#{post.id}"}
            class="list-row block space-y-1"
          >
            <div class="flex flex-wrap items-center gap-2">
              <.category_badge category={thread.category} />
              <.link
                navigate={~p"/categories/#{thread.category_id}/threads/#{thread}" <> "#post-#{post.id}"}
                class="result-title font-semibold hover:text-primary"
              >
                {thread.title}
              </.link>
            </div>
            <p class="result-snippet text-sm text-base-content/80 [&_mark]:bg-warning/40 [&_mark]:text-inherit">
              {raw(headline)}
            </p>
            <p class="text-xs text-base-content/60">
              <.link navigate={~p"/users/#{post.user}"} class="link-hover">@{post.user.username}</.link>
              · <.time_ago id={"result-#{post.id}-time"} at={post.inserted_at} />
            </p>
          </li>
        </ol>
        <.pagination page={@results} path={~p"/search"} params={@query} />
      </section>
    </Layouts.app>
    """
  end
end
