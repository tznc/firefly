defmodule FirestormWeb.Web.ForumComponents do
  @moduledoc """
  Forum-specific UI components: thread lists, posts, avatars, timestamps,
  category badges, rendered markdown, oEmbeds and pagination.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: FirestormWeb.Web.Endpoint,
    router: FirestormWeb.Web.Router,
    statics: FirestormWeb.Web.static_paths()

  import FirestormWeb.Web.CoreComponents, only: [icon: 1]

  alias FirestormWeb.Forums.User
  alias FirestormWeb.Markdown

  ## Helpers

  defdelegate avatar_url(user, size \\ 256), to: User

  @doc "Abbreviated month, day and two-digit year, i.e. `Jul 3, '17`."
  def short_date(date), do: Calendar.strftime(date, "%b %-d, '%y")

  @doc "A category's CSS color: its chosen color, or a hue derived from its slug."
  def category_color(%{color: "#" <> _ = color}), do: color

  def category_color(category) do
    hue =
      for(<<num <- :crypto.hash(:sha, category.slug)>>, do: num)
      |> Enum.sum()
      |> rem(360)

    "oklch(55% 0.13 #{hue})"
  end

  @doc "ISO 8601 UTC string for a timestamp."
  def iso8601(%DateTime{} = time),
    do: time |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  def iso8601(%NaiveDateTime{} = time),
    do: time |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  ## Components

  @doc """
  A `<time>` element showing an ISO 8601 UTC timestamp, humanized to relative
  time ("3 hours ago") in the browser.
  """
  attr :at, :any, required: true
  attr :id, :string, required: true
  attr :class, :string, default: nil

  def time_ago(assigns) do
    assigns = assign(assigns, :iso, iso8601(assigns.at))

    ~H"""
    <time id={@id} datetime={@iso} title={@iso} phx-hook="LocalTime" class={@class}>{@iso}</time>
    """
  end

  @doc "A user's avatar."
  attr :user, :any, required: true
  attr :size, :string, default: "size-10"

  def avatar(assigns) do
    ~H"""
    <div class="avatar">
      <div class={["rounded-full", @size]}>
        <img src={avatar_url(@user)} alt={"#{@user.username}'s avatar"} />
      </div>
    </div>
    """
  end

  @doc "A category badge, colored from the category's slug."
  attr :category, :any, required: true

  def category_badge(assigns) do
    ~H"""
    <.link
      navigate={~p"/categories/#{@category}"}
      class="badge badge-sm border-0 font-medium text-white"
      style={"background-color: #{category_color(@category)}"}
    >
      {@category.title}
    </.link>
    """
  end

  @doc "A page heading with optional action buttons."
  attr :title, :string, required: true
  attr :navigate, :string, default: nil
  slot :subtitle
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header class="flex flex-wrap items-center justify-between gap-4">
      <div>
        <h1 class="text-2xl font-bold tracking-tight">
          <.link :if={@navigate} navigate={@navigate}>{@title}</.link>
          <span :if={!@navigate}>{@title}</span>
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">{render_slot(@subtitle)}</p>
      </div>
      <div :if={@actions != []} class="flex gap-2">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  A list of threads (each decorated with `first_post`, `posts_count` and
  `completely_read?`).
  """
  attr :threads, :list, required: true
  attr :id, :string, default: "threads"
  attr :empty, :string, default: "No threads yet."

  def thread_list(assigns) do
    ~H"""
    <ol id={@id} class="list rounded-box border border-base-300 bg-base-100">
      <li :if={@threads == []} class="list-row text-base-content/60">{@empty}</li>
      <li :for={thread <- @threads} id={"thread-#{thread.id}"} class="list-row items-start">
        <.avatar :if={thread.first_post} user={thread.first_post.user} />
        <div class="list-col-grow min-w-0 space-y-1">
          <div class="flex flex-wrap items-center gap-2">
            <.category_badge :if={Ecto.assoc_loaded?(thread.category)} category={thread.category} />
            <.thread_status thread={thread} />
            <.link
              navigate={~p"/categories/#{thread.category_id}/threads/#{thread}"}
              class="thread-title font-semibold hover:text-primary"
            >
              {thread.title}
            </.link>
          </div>
          <div :if={thread.first_post} class="text-xs text-base-content/60">
            <.link navigate={~p"/users/#{thread.first_post.user}"} class="link-hover">
              @{thread.first_post.user.username}
            </.link>
            · <.time_ago id={"thread-#{thread.id}-time"} at={thread.inserted_at} />
          </div>
          <p :if={thread.first_post} class="line-clamp-2 text-sm text-base-content/80">
            {String.slice(thread.first_post.body, 0..139)}
          </p>
        </div>
        <div class="flex flex-col items-end gap-1">
          <span
            class={[
              "posts-count badge",
              if(thread.completely_read?, do: "badge-ghost", else: "badge-primary")
            ]}
            title={if thread.completely_read?, do: "All read", else: "Unread posts"}
          >
            {thread.posts_count}
          </span>
          <span :if={thread.new?} class="new-badge badge badge-sm badge-accent">new</span>
          <.link
            :if={!thread.new? and thread.unread_count > 0}
            navigate={
              ~p"/categories/#{thread.category_id}/threads/#{thread}" <>
                "#post-#{thread.first_unread_post_id}"
            }
            class="unread-badge badge badge-sm badge-outline badge-primary"
            title="Jump to the first unread post"
          >
            {thread.unread_count} unread
          </.link>
        </div>
      </li>
    </ol>
    """
  end

  @level_info %{
    "watching" => {"hero-eye-solid", "Watching", "Notify me of every new post, and email me"},
    "tracking" => {"hero-eye", "Tracking", "Notify me of every new post (no email)"},
    "normal" => {"hero-bell-slash", "Normal", "Don't notify me"},
    "muted" => {"hero-speaker-x-mark", "Muted", "Don't notify me, and hide from my lists"}
  }

  @doc """
  A dropdown to pick a notification level. Sends `set_level` with `level`.
  `inherited` is the level that applies when none is chosen (e.g. from the
  category).
  """
  attr :id, :string, required: true
  attr :level, :string, default: nil, doc: "the chosen level, or nil"
  attr :inherited, :string, default: "normal"

  def level_picker(assigns) do
    effective = assigns.level || assigns.inherited
    {icon, label, _} = Map.fetch!(@level_info, effective)

    assigns =
      assign(assigns,
        effective: effective,
        icon: icon,
        label: label,
        options: Enum.map(~w(watching tracking normal muted), &{&1, @level_info[&1]})
      )

    ~H"""
    <div id={@id} class="dropdown dropdown-end">
      <div
        tabindex="0"
        role="button"
        class={["btn btn-ghost btn-sm", @effective in ~w(watching tracking) && "text-primary"]}
        title="Notification level"
      >
        <.icon name={@icon} class="size-4" /> <span class="level-label">{@label}</span>
      </div>
      <ul
        tabindex="0"
        class="dropdown-content menu z-10 w-72 rounded-box border border-base-300 bg-base-100 p-2 shadow"
      >
        <li :for={{value, {opt_icon, opt_label, description}} <- @options}>
          <button
            type="button"
            phx-click="set_level"
            phx-value-level={value}
            class={[@effective == value && "menu-active"]}
          >
            <.icon name={opt_icon} class="size-4" />
            <span class="flex flex-col items-start">
              <span class="font-medium">{opt_label}</span>
              <span class="text-xs opacity-70">{description}</span>
            </span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  @doc "Icons for a pinned, closed or archived thread."
  attr :thread, :any, required: true

  def thread_status(assigns) do
    ~H"""
    <span
      :if={@thread.pinned_at}
      class="pinned text-primary"
      title="Pinned"
      aria-label="Pinned"
    ><.icon name="hero-bookmark-solid" class="size-4" /></span>
    <span
      :if={@thread.archived_at}
      class="archived text-base-content/60"
      title="Archived"
      aria-label="Archived"
    ><.icon name="hero-archive-box" class="size-4" /></span>
    <span
      :if={@thread.closed_at && !@thread.archived_at}
      class="closed text-base-content/60"
      title="Closed"
      aria-label="Closed"
    ><.icon name="hero-lock-closed" class="size-4" /></span>
    """
  end

  @doc "Tabs for the Latest / New / Unread / Top thread lists."
  attr :current_path, :string, required: true
  attr :current_user, :any, default: nil

  def list_tabs(assigns) do
    assigns =
      assign(assigns, :tabs, [
        {"Latest", "/", true},
        {"New", "/new", !!assigns.current_user},
        {"Unread", "/unread", !!assigns.current_user},
        {"Top", "/top", true}
      ])

    ~H"""
    <div id="list-tabs" role="tablist" class="tabs tabs-border">
      <.link
        :for={{label, path, shown?} <- @tabs}
        :if={shown?}
        navigate={path}
        role="tab"
        class={["tab", @current_path == path && "tab-active"]}
      >
        {label}
      </.link>
    </div>
    """
  end

  @doc """
  A post with its author, timestamp, rendered body and oEmbeds. Edited posts
  link to their edit history.
  """
  attr :post, :any, required: true
  attr :thread, :any, required: true
  attr :headline, :boolean, default: false, doc: "show the thread title instead of the author"
  attr :can_edit, :boolean, default: false
  attr :refs, :map, default: nil, doc: "`FirestormWeb.Mentions.refs/1` of the page's posts"
  slot :actions

  def post(assigns) do
    ~H"""
    <article
      id={"post-#{@post.id}"}
      class={["card border border-base-300 bg-base-100", @post.deleted_at && "deleted-post opacity-60"]}
    >
      <div class="card-body gap-4 p-5">
        <header class="flex items-center gap-3">
          <.avatar user={@post.user} size="size-9" />
          <div class="min-w-0 flex-1 text-sm">
            <.link
              :if={@headline}
              navigate={~p"/categories/#{@thread.category_id}/threads/#{@thread}"}
              class="font-semibold hover:text-primary"
            >
              {@thread.title}
            </.link>
            <.link
              :if={!@headline}
              navigate={~p"/users/#{@post.user}"}
              class="username font-semibold hover:text-primary"
            >
              @{@post.user.username}
            </.link>
            <div class="text-xs text-base-content/60">
              <.link navigate={~p"/categories/#{@thread.category_id}/threads/#{@thread}" <> "#post-#{@post.id}"}>
                <.time_ago id={"post-#{@post.id}-time"} at={@post.inserted_at} />
              </.link>
              <span
                :if={@post.deleted_at}
                class="badge badge-error badge-sm"
                title={deleted_title(@post)}
              >
                deleted
              </span>
              <.link
                :if={@post.edited_at}
                navigate={
                  ~p"/categories/#{@thread.category_id}/threads/#{@thread}/posts/#{@post.id}/history"
                }
                class="edited link-hover"
                title="Edited: view the edit history"
              >
                · <.icon name="hero-pencil" class="size-3" /> edited
              </.link>
            </div>
          </div>
        </header>
        <.markdown id={"post-#{@post.id}-body"} body={@post.body} refs={@refs} />
        <.oembeds :if={@post.oembeds} oembeds={@post.oembeds} />
        <footer class="flex items-center justify-end gap-1">
          {render_slot(@actions)}
          <.link
            :if={@can_edit}
            navigate={~p"/categories/#{@thread.category_id}/threads/#{@thread}/posts/#{@post.id}/edit"}
            class="btn btn-ghost btn-sm btn-square"
            aria-label={"Edit post #{@post.id}"}
          >
            <.icon name="hero-pencil-square" class="size-4" />
          </.link>
          <.link
            navigate={~p"/categories/#{@thread.category_id}/threads/#{@thread}" <> "#post-#{@post.id}"}
            class="btn btn-ghost btn-sm btn-square"
            aria-label={"link to post #{@post.id}"}
          >
            <.icon name="hero-link" class="size-4" />
          </.link>
          <.link
            :if={quotable?(@post, @thread)}
            id={"post-#{@post.id}-quote"}
            navigate={quote_path(@post, @thread)}
            phx-hook="QuoteSelection"
            data-href={quote_path(@post, @thread)}
            data-body={"post-#{@post.id}-body"}
            class="quote-link btn btn-ghost btn-sm btn-square"
            aria-label={"Quote post #{@post.id}"}
            title="Quote (select text in the post to quote just that)"
          >
            <.icon name="hero-chat-bubble-bottom-center-text" class="size-4" />
          </.link>
          <.link
            navigate={~p"/categories/#{@thread.category_id}/threads/#{@thread}/posts/new"}
            class="btn btn-ghost btn-sm btn-square"
            aria-label={"Reply to post #{@post.id}"}
          >
            <.icon name="hero-arrow-uturn-left" class="size-4" />
          </.link>
        </footer>
      </div>
    </article>
    """
  end

  defp quotable?(post, thread),
    do: is_nil(post.deleted_at) and is_nil(thread.closed_at) and is_nil(thread.archived_at)

  defp quote_path(post, thread),
    do: ~p"/categories/#{thread.category_id}/threads/#{thread}/posts/new?#{[quote: post.id]}"

  defp deleted_title(%{deleted_by: %User{username: username}}), do: "Deleted by @#{username}"
  defp deleted_title(_post), do: "Deleted"

  @doc """
  A post's likes: a toggle button with the count for members who may like it
  (sends `toggle_like` with the post `id`), otherwise just the count. Hovering
  shows who liked it.
  """
  attr :post, :any, required: true
  attr :likers, :list, default: [], doc: "the users who liked the post, in order"
  attr :current_user, :any, default: nil
  attr :can_like, :boolean, default: false

  def like_button(assigns) do
    liked? =
      !!assigns.current_user and Enum.any?(assigns.likers, &(&1.id == assigns.current_user.id))

    assigns = assign(assigns, liked?: liked?, tip: likers_tip(assigns.likers))

    ~H"""
    <div
      :if={@can_like or @likers != []}
      id={"post-#{@post.id}-likes"}
      class={["likes", @likers != [] && "tooltip"]}
      data-tip={@tip}
    >
      <button
        :if={@can_like}
        type="button"
        phx-click="toggle_like"
        phx-value-id={@post.id}
        class={["btn btn-ghost btn-sm", @liked? && "text-error"]}
        aria-label={if @liked?, do: "Unlike post #{@post.id}", else: "Like post #{@post.id}"}
        aria-pressed={to_string(@liked?)}
      >
        <.icon name={if @liked?, do: "hero-heart-solid", else: "hero-heart"} class="size-4" />
        <span :if={@likers != []} class="like-count">{length(@likers)}</span>
      </button>
      <span :if={!@can_like} class="inline-flex items-center gap-1 px-3 text-sm text-base-content/70">
        <.icon name="hero-heart" class="size-4" />
        <span class="like-count">{length(@likers)}</span>
      </span>
    </div>
    """
  end

  @tip_names 10

  defp likers_tip([]), do: nil

  defp likers_tip(likers) do
    {named, rest} = Enum.split(likers, @tip_names)
    names = Enum.map_join(named, ", ", &"@#{&1.username}")
    if rest == [], do: "Liked by #{names}", else: "Liked by #{names} and #{length(rest)} more"
  end

  @doc "What members see in place of a deleted post."
  attr :post, :any, required: true

  def deleted_post(assigns) do
    ~H"""
    <article
      id={"post-#{@post.id}"}
      class="deleted-post rounded-box border border-dashed border-base-300 px-5 py-3 text-sm italic text-base-content/60"
    >
      <.icon name="hero-trash" class="size-4" /> This post was deleted.
    </article>
    """
  end

  @doc "Markdown rendered (and sanitized) to HTML, with code highlighting."
  attr :id, :string, required: true
  attr :body, :string, required: true
  attr :refs, :map, default: nil, doc: "see `FirestormWeb.Markdown.render/2`"

  def markdown(assigns) do
    ~H"""
    <div id={@id} phx-hook="Highlight" class="post-body prose prose-sm max-w-none">
      {Phoenix.HTML.raw(Markdown.render(@body, @refs))}
    </div>
    """
  end

  @doc """
  A word diff (see `FirestormWeb.Forums.Diff`) with insertions and deletions
  highlighted. The text is HTML-escaped; the markup is built here so that no
  stray template whitespace ends up inside the preformatted text.
  """
  attr :diff, :list, required: true

  def post_diff(assigns) do
    assigns = assign(assigns, :html, diff_html(assigns.diff))

    ~H"""
    <div class="post-diff whitespace-pre-wrap break-words rounded-box bg-base-200 p-4 font-mono text-sm">{@html}</div>
    """
  end

  defp diff_html(diff) do
    {:safe,
     Enum.map(diff, fn {op, text} ->
       {:safe, escaped} = Phoenix.HTML.html_escape(text)

       case op do
         :eq -> escaped
         :ins -> [~s(<ins class="bg-success/25 no-underline">), escaped, "</ins>"]
         :del -> [~s(<del class="bg-error/20 text-error">), escaped, "</del>"]
       end
     end)}
  end

  @doc "Rendered oEmbeds for the URLs in a post."
  attr :oembeds, :list, required: true

  def oembeds(assigns) do
    ~H"""
    <div :for={{url, oembed} <- @oembeds} class="oembed" data-oembed-url={url}>
      {render_oembed(oembed)}
    </div>
    """
  end

  defp render_oembed(oembed), do: Phoenix.HTML.raw(FirestormWeb.OEmbed.to_html(oembed))

  @doc """
  Pagination links for a `Scrivener.Page`, linking to `path?page=N`.
  """
  attr :page, Scrivener.Page, required: true
  attr :path, :string, required: true

  def pagination(assigns) do
    assigns =
      assign(assigns, :window, page_window(assigns.page.page_number, assigns.page.total_pages))

    ~H"""
    <nav :if={@page.total_pages > 1} class="flex justify-center" aria-label="Pagination">
      <div class="join">
        <.link
          :if={@page.page_number > 1}
          patch={"#{@path}?page=#{@page.page_number - 1}"}
          class="join-item btn btn-sm"
          aria-label="Previous page"
        >
          «
        </.link>
        <.link
          :for={n <- @window}
          patch={"#{@path}?page=#{n}"}
          class={["join-item btn btn-sm", n == @page.page_number && "btn-active"]}
          aria-current={n == @page.page_number && "page"}
        >
          {n}
        </.link>
        <.link
          :if={@page.page_number < @page.total_pages}
          patch={"#{@path}?page=#{@page.page_number + 1}"}
          class="join-item btn btn-sm"
          aria-label="Next page"
        >
          »
        </.link>
      </div>
    </nav>
    """
  end

  @doc false
  def page_window(current, total) do
    Enum.to_list(max(1, current - 2)..min(total, current + 2)//1)
  end
end
