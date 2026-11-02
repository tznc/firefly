defmodule FirestormWeb.Web.StaffLive.Review do
  @moduledoc """
  The staff review queue (admins only; see `FirestormWeb.Review`): flagged
  posts and posts awaiting approval. Updates live as flags come in and as
  other staff decide.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Penalties, Repo, Review}
  alias FirestormWeb.Forums.{Flag, Post}

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :review) do
      {:ok, socket |> assign(:page_title, "Review") |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @doc false
  def review_changed(socket), do: load(socket)

  defp load(socket) do
    assign(socket, flagged: Review.flagged_posts(), queued: Review.queued_posts())
  end

  @impl true
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

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Review" navigate={~p"/staff/review"}>
        <:subtitle>Flagged posts and posts awaiting approval. Every decision goes to the staff log.</:subtitle>
      </.page_header>

      <p :if={@flagged == [] and @queued == []} id="review-empty" class="text-base-content/70">
        Nothing to review.
      </p>

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
                <.link navigate={~p"/users/#{flag.user}"} class="font-medium">@{flag.user.username}</.link>:
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
        <article :for={post <- @queued} id={"queued-#{post.id}"} class="card border border-base-300 bg-base-100">
          <div class="card-body gap-3">
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
