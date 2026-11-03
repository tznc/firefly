defmodule FireflyWeb.StaffLive.Review do
  @moduledoc """
  The staff review queue (admins only; see `Firefly.Moderation.Review`): flagged
  posts, posts awaiting approval and flagged chat messages; queued posts can be approved or
  rejected together. Updates live as flags come in and as
  other staff decide.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Chat, Repo}
  alias Firefly.Moderation.{Penalties, Review}
  alias Firefly.Discussion.Post
  alias Firefly.Moderation.Flag

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :review) do
      {:ok, socket |> assign(page_title: "Review", selected: MapSet.new()) |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @doc false
  def review_changed(socket), do: load(socket)

  # The selection keeps only posts still in the queue.
  defp load(socket) do
    queued = Review.queued_posts()
    selected = MapSet.intersection(socket.assigns.selected, MapSet.new(queued, & &1.id))

    assign(socket,
      flagged: Review.flagged_posts(),
      queued: queued,
      selected: selected,
      chat_flagged: Chat.flagged_messages()
    )
  end

  @impl true
  def handle_event("select", %{"post_id" => id}, socket) do
    id = String.to_integer(id)
    selected = socket.assigns.selected

    selected =
      if MapSet.member?(selected, id),
        do: MapSet.delete(selected, id),
        else: MapSet.put(selected, id)

    {:noreply, assign(socket, :selected, selected)}
  end

  def handle_event("select_all", _params, socket),
    do: {:noreply, assign(socket, :selected, MapSet.new(socket.assigns.queued, & &1.id))}

  def handle_event(event, params, socket) when event in ["approve_selected", "reject_selected"] do
    admin = socket.assigns.current_user
    ids = MapSet.to_list(socket.assigns.selected)

    result =
      cond do
        not can?(admin, :review) -> {:error, :unauthorized}
        event == "approve_selected" -> Review.approve_many(ids, admin)
        true -> Review.reject_many(ids, admin, params["reason"])
      end

    case result do
      {:ok, count} ->
        verb = if event == "approve_selected", do: "Approved", else: "Rejected"

        {:noreply,
         socket
         |> put_flash(:info, "#{verb} #{count} of #{length(ids)} selected posts.")
         |> assign(:selected, MapSet.new())
         |> load()}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, denied_message(admin))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Review.message(reason))}
    end
  end

  def handle_event(event, %{"message_id" => id}, socket)
      when event in ~w(chat_agree chat_disagree) do
    admin = socket.assigns.current_user
    decision = if event == "chat_agree", do: :agree, else: :disagree

    with %{} = message <- Chat.get_message(id),
         {:ok, _} <- Chat.review_flags(message, admin, decision) do
      done =
        if decision == :agree,
          do: "Agreed: the message was deleted.",
          else: "Disagreed: the message stays."

      {:noreply, socket |> put_flash(:info, done) |> load()}
    else
      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, denied_message(admin))}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, Review.message(reason)) |> load()}

      nil ->
        {:noreply, load(socket)}
    end
  end

  def handle_event(event, params, socket) do
    admin = socket.assigns.current_user

    if can?(admin, :review) do
      post = Repo.get(Post, params["post_id"])
      {:noreply, decide(socket, event, post, admin, params)}
    else
      {:noreply, put_flash(socket, :error, denied_message(admin))}
    end
  end

  defp decide(socket, _event, nil, _admin, _params),
    do: socket |> put_flash(:error, Review.message(:not_queued)) |> load()

  defp decide(socket, event, post, admin, params) do
    case run(event, post, admin, params) do
      {{:ok, _}, done} -> socket |> put_flash(:info, done) |> load()
      {{:error, reason}, _} -> socket |> put_flash(:error, Review.message(reason)) |> load()
    end
  end

  defp run("agree_hide", post, admin, _params),
    do: {Review.agree(post, admin, :hide), "Agreed: the post stays hidden."}

  defp run("agree_delete", post, admin, _params),
    do: {Review.agree(post, admin, :delete), "Agreed: the post was deleted."}

  defp run("agree_silence", post, admin, params) do
    penalty = Map.take(params, ["duration", "reason"])
    {Review.agree(post, admin, {:silence, penalty}), "Agreed: the author is silenced."}
  end

  defp run("disagree", post, admin, _params),
    do: {Review.disagree(post, admin), "Disagreed: the post is shown again."}

  defp run("defer", post, admin, _params),
    do: {Review.defer(post, admin), "Deferred: the flags are set aside."}

  defp run("approve", post, admin, _params),
    do: {Review.approve(post, admin), "Approved and published."}

  defp run("reject", post, admin, params),
    do: {Review.reject(post, admin, params["reason"]), "Rejected; the author was told."}

  defp chat_link(message),
    do: ~p"/chat/c/#{message.channel.slug || "dm"}/#{message.channel.id}?message=#{message.id}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Review" navigate={~p"/staff/review"}>
        <:subtitle>Flagged posts and posts awaiting approval. Every decision goes to the staff log.</:subtitle>
      </.page_header>

      <p
        :if={@flagged == [] and @queued == [] and @chat_flagged == []}
        id="review-empty"
        class="text-base-content/70"
      >
        Nothing to review.
      </p>

      <section :if={@chat_flagged != []} id="chat-flagged" class="space-y-4">
        <h2 class="text-lg font-semibold">Flagged chat messages</h2>
        <article
          :for={message <- @chat_flagged}
          id={"chat-flagged-#{message.id}"}
          class="card border border-warning/50 bg-base-100"
        >
          <div class="card-body gap-3">
            <div class="flex flex-wrap items-center gap-2 text-sm">
              <span class="font-semibold">
                {if message.user, do: "@" <> message.user.username, else: "deleted user"}
              </span>
              in
              <.link navigate={chat_link(message)} class="link">
                {if message.channel.kind == "direct",
                  do: "a direct message (" <> Enum.map_join(message.channel.members, ", ", &("@" <> &1.username)) <> ")",
                  else: "#" <> message.channel.name}
              </.link>
              <span :if={message.deleted_at} class="badge badge-error badge-xs">deleted</span>
            </div>
            <blockquote class="border-l-2 border-base-300 pl-3 text-sm whitespace-pre-wrap">{message.body}</blockquote>
            <ul class="space-y-1 text-sm">
              <li :for={flag <- message.flags} class="flag">
                <.icon name="hero-flag" class="size-4 text-warning" />
                <span class="font-medium">{if flag.user, do: "@" <> flag.user.username, else: "System"}</span>:
                {Flag.reason_label(flag.reason)}<span :if={flag.note}> ({flag.note})</span>
              </li>
            </ul>
            <div class="flex flex-wrap gap-2">
              <button
                phx-click="chat_agree"
                phx-value-message_id={message.id}
                data-confirm="Delete this message?"
                class="btn btn-sm btn-error"
              >
                Agree and delete
              </button>
              <button phx-click="chat_disagree" phx-value-message_id={message.id} class="btn btn-sm">
                Disagree
              </button>
            </div>
          </div>
        </article>
      </section>

      <section :if={@flagged != []} id="flagged" class="space-y-4">
        <h2 class="text-lg font-semibold">Flagged posts</h2>
        <article
          :for={post <- @flagged}
          id={"flagged-#{post.id}"}
          class="card border border-warning/50 bg-base-100"
        >
          <div class="card-body gap-3">
            <.item_header post={post} />
            <ul class="space-y-1 text-sm">
              <li :for={flag <- post.flags} class="flag">
                <.icon name="hero-flag" class="size-4 text-warning" />
                <.link :if={flag.user} navigate={~p"/users/#{flag.user}"} class="font-medium">@{flag.user.username}</.link><span
                  :if={!flag.user}
                  class="font-medium"
                >System</span>:
                {Flag.reason_label(flag.reason)}<span :if={flag.note}> ({flag.note})</span>
                · <.time_ago id={"flag-#{flag.id}-at"} at={flag.inserted_at} />
              </li>
            </ul>
            <div class="flex flex-wrap gap-2">
              <button phx-click="agree_hide" phx-value-post_id={post.id} class="btn btn-sm btn-warning">
                Agree and hide
              </button>
              <button
                phx-click="agree_delete"
                phx-value-post_id={post.id}
                data-confirm="Delete this post?"
                class="btn btn-sm btn-error"
              >
                Agree and delete
              </button>
              <button phx-click="disagree" phx-value-post_id={post.id} class="btn btn-sm">
                Disagree and restore
              </button>
              <button phx-click="defer" phx-value-post_id={post.id} class="btn btn-sm btn-ghost">
                Defer
              </button>
            </div>
            <form
              id={"silence-#{post.id}"}
              phx-submit="agree_silence"
              class="flex flex-wrap items-end gap-2"
            >
              <input type="hidden" name="post_id" value={post.id} />
              <select name="duration" aria-label="Silence for" class="select select-sm w-auto">
                {Phoenix.HTML.Form.options_for_select(Penalties.durations() -- [{"Until a date", "date"}], "1w")}
              </select>
              <input
                type="text"
                name="reason"
                value="Your post was flagged and staff agreed."
                aria-label="Reason (the author sees it)"
                class="input input-sm min-w-64 flex-1"
              />
              <button class="btn btn-sm btn-warning">Agree and silence author</button>
            </form>
          </div>
        </article>
      </section>

      <section :if={@queued != []} id="queued" class="space-y-4">
        <h2 class="text-lg font-semibold">Awaiting approval</h2>
        <div id="bulk-review" class="flex flex-wrap items-end gap-2 text-sm">
          <button type="button" phx-click="select_all" class="btn btn-ghost btn-xs">Select all</button>
          <%= if MapSet.size(@selected) > 0 do %>
            <span id="selected-count" class="font-medium">{MapSet.size(@selected)} selected:</span>
            <button phx-click="approve_selected" class="btn btn-xs btn-primary">Approve selected</button>
            <form id="reject-selected" phx-submit="reject_selected" class="join">
              <input
                type="text"
                name="reason"
                placeholder="Why not (the authors see it)"
                aria-label="Reason for rejecting the selected posts"
                class="input input-xs join-item min-w-56"
              />
              <button class="btn btn-xs btn-error join-item">Reject selected</button>
            </form>
          <% end %>
        </div>
        <article :for={post <- @queued} id={"queued-#{post.id}"} class="card border border-base-300 bg-base-100">
          <div class="card-body gap-3">
            <label class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                class="checkbox checkbox-sm"
                phx-click="select"
                phx-value-post_id={post.id}
                checked={MapSet.member?(@selected, post.id)}
              /> Select
            </label>
            <.item_header post={post} />
            <p class="text-xs text-base-content/60">{if post.first?, do: "New thread", else: "Reply"}</p>
            <p :if={post.queued_reason} class="alert alert-info py-2 text-sm">{post.queued_reason}</p>
            <div class="flex flex-wrap items-end gap-2">
              <button phx-click="approve" phx-value-post_id={post.id} class="btn btn-sm btn-primary">
                Approve
              </button>
              <form id={"reject-#{post.id}"} phx-submit="reject" class="flex flex-1 items-end gap-2">
                <input type="hidden" name="post_id" value={post.id} />
                <input
                  type="text"
                  name="reason"
                  placeholder="Why not (the author sees it)"
                  aria-label={"Reason for rejecting post #{post.id}"}
                  class="input input-sm min-w-64 flex-1"
                />
                <button class="btn btn-sm btn-error">Reject</button>
              </form>
            </div>
          </div>
        </article>
      </section>
    </Layouts.app>
    """
  end

  attr :post, :any, required: true

  defp item_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-2 text-sm">
      <.category_badge category={@post.thread.category} />
      <.link
        navigate={~p"/categories/#{@post.thread.category_id}/threads/#{@post.thread}" <> "#post-#{@post.id}"}
        class="font-semibold hover:text-primary"
      >
        {@post.thread.title}
      </.link>
      by <.link navigate={~p"/users/#{@post.user}"} class="font-medium">@{@post.user.username}</.link>
      <span :if={Post.hidden?(@post)} class="badge badge-warning badge-sm">hidden</span>
    </div>
    <.markdown id={"review-#{@post.id}-body"} body={@post.body} />
    """
  end
end
