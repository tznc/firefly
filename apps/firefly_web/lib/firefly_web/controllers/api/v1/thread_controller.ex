defmodule FireflyWeb.Api.V1.ThreadController do
  @moduledoc """
  Threads: the lists (`latest`, `new`, `unread`, `top`), reading a thread
  and its posts, starting, editing and deleting one, replying, and the
  topic tools (pin, close, archive, move, accepted answers), each with the
  web interface's permissions and posting checks.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.{Discussion, Repo}
  alias Firefly.Discussion.{Bookmarks, Post, Solved, Thread}
  alias Firefly.Moderation.Posting
  alias Firefly.Notifications.Subscriptions
  alias FireflyWeb.Api.Pagination
  alias FireflyWeb.Api.V1.{CategoryController, PostJSON, ThreadJSON}

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  @reads [:index, :show, :posts]
  plug(:require_scope, "read" when action in @reads)
  plug(:require_scope, "users:write" when action in [:notification_level, :read])
  plug(:require_scope, "topics:write" when action not in [:notification_level, :read | @reads])

  @views ~w(latest new unread top)

  def index(conn, params) do
    user = current_user(conn)
    view = params["view"] || "latest"

    cond do
      view not in @views -> {:error, "view must be one of: #{Enum.join(@views, ", ")}"}
      view in ["new", "unread"] and is_nil(user) -> require_user(conn, [])
      true -> Pagination.render(conn, listing(view, user, params), params, &ThreadJSON.listed/1)
    end
  end

  # `latest` is read a page at a time (the others are short lists).
  defp listing("latest", user, _params),
    do: fn offset, limit ->
      user |> Discussion.latest_threads(offset + limit) |> Enum.drop(offset)
    end

  defp listing("new", user, _params), do: Discussion.new_threads(user)
  defp listing("unread", user, _params), do: Discussion.unread_threads(user)

  defp listing("top", user, params) do
    period = if params["period"] in Discussion.top_periods(), do: params["period"], else: "month"
    Discussion.top_threads(period, user)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, thread} <- fetch(id, current_user(conn)) do
      ok(conn, thread |> Repo.preload(:tags) |> ThreadJSON.listed())
    end
  end

  def create(conn, params) do
    user = current_user(conn)

    with {:ok, category} <- CategoryController.fetch(params["category_id"], user),
         :ok <- Posting.check(user),
         {:ok, thread} <-
           Discussion.create_thread(category, user, %{
             title: params["title"],
             body: params["body"],
             tags: tags(params["tags"])
           }) do
      ok(conn, thread |> Repo.preload(:tags, force: true) |> ThreadJSON.listed(), 201)
    end
  end

  def update(conn, %{"id" => id} = params) do
    user = current_user(conn)

    attrs =
      for {key, value} <- Map.take(params, ~w(title tags)), into: %{}, do: {key, tags(value)}

    with {:ok, thread} <- fetch(id, user),
         :ok <- permit(user, :update_thread, thread),
         :ok <- Posting.check(user, :like),
         {:ok, thread} <- Discussion.update_thread(thread, attrs, user) do
      ok(conn, thread |> Repo.preload(:tags, force: true) |> ThreadJSON.listed())
    end
  end

  def delete(conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, thread} <- fetch(id, user),
         :ok <- permit(user, :delete_thread, thread),
         {:ok, _} <- Discussion.delete_thread(thread, user) do
      no_content(conn)
    end
  end

  @doc "`POST /threads/:id/pin|close|archive` with `{\"value\": true|false}`."
  def moderate(conn, %{"id" => id, "action" => action} = params) do
    user = current_user(conn)
    value = params["value"] not in [false, "false"]
    # Leaders (trust level 4) pin and close; archiving is for admins.
    policy = if action == "archive", do: :moderate_thread, else: :close_thread

    with {:ok, thread} <- fetch(id, user),
         :ok <- permit(user, policy, thread),
         {:ok, thread} <- moderate(thread, action, value, user) do
      ok(conn, ThreadJSON.listed(thread))
    end
  end

  defp moderate(thread, "pin", value, user), do: Discussion.pin_thread(thread, value, user)
  defp moderate(thread, "close", value, user), do: Discussion.close_thread(thread, value, user)

  defp moderate(thread, "archive", value, user),
    do: Discussion.archive_thread(thread, value, user)

  def move(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, thread} <- fetch(id, user),
         :ok <- permit(user, :move_thread, thread),
         {:ok, category} <- CategoryController.fetch(params["category_id"], user),
         {:ok, thread} <- Discussion.move_thread(thread, category, user) do
      ok(conn, ThreadJSON.listed(thread))
    end
  end

  def notification_level(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, level} <- notification_level(params),
         {:ok, thread} <- fetch(id, user),
         {:ok, _} <- Subscriptions.set_thread_level(user, thread, level) do
      ok(conn, %{level: level})
    end
  end

  def read(conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, thread} <- fetch(id, user) do
      Discussion.mark_thread_read(user, thread)
      no_content(conn)
    end
  end

  @doc """
  The thread's posts, oldest first, as its page shows them: replies
  awaiting approval only to their author and admins; deleted, hidden ones
  without their content unless the user may see it.
  """
  def posts(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, thread} <- fetch(id, user) do
      posts =
        thread
        |> Repo.preload(posts: [:user])
        |> Map.fetch!(:posts)
        |> Enum.reject(&(Post.queued?(&1) and not can_view_hidden?(user, &1)))

      Pagination.render(conn, posts, params, post_renderer(posts, user))
    end
  end

  @doc "A function rendering each of `posts` with the viewer's state (likes, bookmarks)."
  def post_renderer(posts, user) do
    likers = Discussion.likers(posts)
    bookmarked = Bookmarks.bookmarked_ids(user, posts)
    refs = Firefly.Discussion.Mentions.refs(Enum.map(posts, & &1.body), user)

    fn post ->
      liked_by = Map.get(likers, post.id, [])

      PostJSON.full(post, refs, user, %{
        like_count: length(liked_by),
        liked: user != nil and Enum.any?(liked_by, &(&1.id == user.id)),
        bookmarked: MapSet.member?(bookmarked, post.id)
      })
    end
  end

  defp can_view_hidden?(user, post), do: permit(user, :view_hidden_post, post) == :ok

  def reply(conn, %{"id" => id} = params) do
    FireflyWeb.Api.V1.PostController.create(conn, Map.put(params, "thread_id", id))
  end

  def accept_answer(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, thread} <- fetch(id, user),
         %Post{} = post <- Discussion.get_post(thread, int(params["post_id"]) || 0),
         {:ok, thread} <- Solved.accept(thread, post, user) do
      ok(conn, ThreadJSON.listed(thread))
    else
      {:error, reason} when reason in [:first_post, :not_acceptable] ->
        {:error, {422, Solved.message(reason)}}

      other ->
        other
    end
  end

  def unaccept_answer(conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, thread} <- fetch(id, user) do
      case Solved.unaccept(thread, user) do
        {:ok, thread} -> ok(conn, ThreadJSON.listed(thread))
        {:error, :not_solved} -> {:error, {422, Solved.message(:not_solved)}}
        error -> error
      end
    end
  end

  # Tags as the composer takes them: one comma-separated string.
  defp tags(tags) when is_list(tags), do: Enum.join(tags, ", ")
  defp tags(tags), do: tags

  @doc "The thread `id` if `user` may read it, else `{:error, :not_found}`."
  def fetch(id, user) do
    with id when is_integer(id) <- int(id),
         %Thread{} = thread <- Discussion.get_thread(id),
         :ok <- permit(user, :view_thread, thread) do
      {:ok, thread}
    else
      _missing_or_hidden -> {:error, :not_found}
    end
  end
end
