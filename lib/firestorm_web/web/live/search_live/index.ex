defmodule FirestormWeb.Web.SearchLive.Index do
  @moduledoc """
  Full-text search (see `FirestormWeb.Search`). The query and filters live in
  the URL (`/search?q=...&category=...`), so results can be linked and paged.

  Searches are rate limited (the `:search` bucket, per user or per client IP
  for visitors). Opening a search in the browser runs it twice, for the
  static render and once connected, and both count: the static one can't be
  skipped, or plain HTTP requests would search for free.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.{Forums, RateLimit, Search}

  @controls ~w(category tag user in order muted)

  @impl true
  def mount(_params, _session, socket) do
    categories =
      Enum.map(Forums.list_categories(socket.assigns.current_user), &{&1.title, &1.slug})

    remote_ip =
      case get_connect_info(socket, :peer_data) do
        %{address: address} -> address
        _unknown -> "unknown"
      end

    {:ok,
     assign(socket,
       page_title: "Search",
       categories: categories,
       remote_ip: remote_ip,
       rate_limited?: false
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = Map.take(params, ["q" | @controls])
    search = Search.parse(params["q"], query)

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:searched?, Search.present?(search))
     |> assign(:form, to_form(query, as: :search))
     |> run(search, params["page"] || 1)}
  end

  defp run(socket, search, page) do
    %{current_user: user, remote_ip: remote_ip} = socket.assigns

    cond do
      not Search.present?(search) ->
        assign(socket, results: Search.no_results(), rate_limited?: false)

      RateLimit.check_search(user, remote_ip) == :ok ->
        assign(socket, results: Search.run(search, user, page), rate_limited?: false)

      true ->
        assign(socket, results: Search.no_results(), rate_limited?: true)
    end
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
          <label :if={@current_user} class="label self-end pb-3 text-sm">
            <input
              type="checkbox"
              name="search[muted]"
              value="include"
              checked={@form[:muted].value == "include"}
              class="checkbox checkbox-sm"
            /> Include muted
          </label>
        </div>
        <p class="text-xs text-base-content/60">
          Also in the search box: <code>category:slug</code>, <code>tag:name</code>,
          <code>@username</code>, <code>in:title</code>, <code>order:latest</code>, <code>"exact phrase"</code>, <code>-exclude</code>.
        </p>
      </.form>

      <p :if={@rate_limited?} id="search-rate-limited" class="alert alert-warning">
        {RateLimit.message()}
      </p>

      <section :if={@searched? and not @rate_limited?} id="search-results" class="space-y-4">
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
