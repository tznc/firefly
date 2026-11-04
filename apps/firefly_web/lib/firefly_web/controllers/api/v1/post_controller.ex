defmodule FireflyWeb.Api.V1.PostController do
  @moduledoc """
  Posts: reading one, replying (`POST /posts` with `thread_id`, or `POST
  /threads/:id/posts`), editing, deleting and restoring, likes,
  bookmarks, flags, wiki posts and polls, each with the web interface's
  permissions and posting checks.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.{Discussion, RateLimit, Repo}
  alias Firefly.Discussion.{Bookmarks, Polls, Post}
  alias Firefly.Moderation.{Flags, Posting}
  alias FireflyWeb.Api.V1.ThreadController

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "read" when action in [:show, :poll])
  plug(:require_scope, "topics:write" when action not in [:show, :poll])

  def show(conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, post, _thread} <- fetch(id, user) do
      ok(conn, render_post(post, user))
    end
  end

  def create(conn, %{"thread_id" => thread_id} = params) do
    user = current_user(conn)
    body = get_in(params, ["post", "body"]) || params["body"]

    # A merged thread's replies go where its posts went.
    with %{} = thread <- Discussion.get_thread_after_merges(int(thread_id) || 0),
         :ok <- not_found(permit(user, :view_thread, thread)),
         :ok <- Posting.check(user, thread),
         {:ok, post} <- Discussion.create_post(thread, user, %{body: body}) do
      ok(conn, render_post(post, user), 201)
    end
  end

  def create(_conn, _params), do: {:error, "thread_id is required"}

  def update(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, post, thread} <- fetch(id, user),
         :ok <- permit(user, :edit_post, %{post: post, thread: thread}),
         :ok <- posting_check(user, post, thread),
         {:ok, post} <- Discussion.update_post(post, user, %{body: params["body"]}) do
      ok(conn, render_post(post, user))
    else
      {:error, reason} when reason in [:deleted, :edited_elsewhere] ->
        {:error, {409, "The post changed meanwhile; fetch it and try again."}}

      other ->
        other
    end
  end

  # Someone else's wiki post: as if replying in the thread (slow mode too).
  defp posting_check(user, post, thread) do
    if Post.wiki?(post) and post.user_id != user.id,
      do: Posting.check(user, thread),
      else: Posting.check(user)
  end

  def delete(conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, post, thread} <- fetch(id, user),
         :ok <- permit(user, :delete_post, %{post: post, thread: thread}),
         {:ok, _post} <- Discussion.delete_post(post, user) do
      no_content(conn)
    else
      {:error, :first_post} -> {:error, {422, "Delete the thread to remove its first post."}}
      other -> other
    end
  end

  def restore(conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, post, _thread} <- fetch(id, user),
         :ok <- permit(user, :restore_post),
         {:ok, post} <- Discussion.restore_post(post, user) do
      ok(conn, render_post(post, user))
    end
  end

  def like(conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, post, thread} <- fetch(id, user),
         :ok <- permit(user, :like_post, %{post: post, thread: thread}),
         :ok <- Posting.check(user, :like),
         :ok <- RateLimit.check_like(user) do
      liked? = Discussion.liked?(post, user)

      cond do
        conn.method == "PUT" and not liked? -> Discussion.like_post(post, user)
        conn.method == "DELETE" and liked? -> Discussion.unlike_post(post, user)
        true -> :unchanged
      end

      ok(conn, render_post(post, user))
    end
  end

  def bookmark(%{method: "DELETE"} = conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, post, _thread} <- fetch(id, user) do
      Bookmarks.unbookmark(user, post)
      no_content(conn)
    end
  end

  def bookmark(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, post, _thread} <- fetch(id, user),
         {:ok, bookmark} <- existing_or_new_bookmark(user, post),
         {:ok, bookmark} <-
           Bookmarks.update(user, bookmark.id, Map.take(params, ~w(note reminder custom_at))) do
      ok(conn, %{
        id: bookmark.id,
        post_id: post.id,
        note: bookmark.note,
        remind_at: bookmark.remind_at
      })
    end
  end

  defp existing_or_new_bookmark(user, post) do
    case Bookmarks.get_for_post(user, post) do
      nil -> Bookmarks.bookmark(user, post)
      bookmark -> {:ok, bookmark}
    end
  end

  def flag(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, post, thread} <- fetch(id, user),
         :ok <- permit(user, :flag_post, %{post: post, thread: thread}) do
      case Flags.flag_post(post, user, Map.take(params, ~w(reason note))) do
        {:ok, flag} -> ok(conn, %{id: flag.id, post_id: post.id, reason: flag.reason}, 201)
        {:error, reason} when is_atom(reason) -> {:error, {422, Flags.message(reason)}}
        error -> error
      end
    end
  end

  def wiki(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, post, _thread} <- fetch(id, user),
         :ok <- permit(user, :toggle_wiki),
         {:ok, post} <- Discussion.set_wiki(post, params["wiki"] not in [false, "false"], user) do
      ok(conn, render_post(post, user))
    end
  end

  def poll(conn, %{"id" => id}) do
    user = current_user(conn)

    with {:ok, post, _thread} <- fetch(id, user),
         %{} = view <- Polls.view_for(post, user) do
      ok(conn, poll_json(view))
    end
  end

  @doc """
  `POST /posts/:id/poll/vote`: `option` (single choice), `options` (a
  list, multiple choice) or `ranks` (option id to rank, ranked).
  """
  def vote(conn, %{"id" => id} = params) do
    user = current_user(conn)

    with {:ok, post, thread} <- fetch(id, user),
         %{} = view <- Polls.view_for(post, user),
         :ok <- permit(user, :vote_poll, %{post: post, thread: thread}) do
      case Polls.vote(view.poll, user, params) do
        {:ok, view} -> ok(conn, poll_json(view))
        {:error, reason} -> {:error, {422, Polls.message(reason)}}
      end
    end
  end

  @doc "`POST /posts/:id/poll/close` and `/reopen`."
  def close_poll(conn, %{"id" => id, "action" => action}) do
    user = current_user(conn)

    with {:ok, post, _thread} <- fetch(id, user),
         %{} = view <- Polls.view_for(post, user) do
      result =
        if action == "close",
          do: Polls.close(view.poll, user),
          else: Polls.reopen(view.poll, user)

      case result do
        {:ok, _poll} -> ok(conn, poll_json(Polls.view_for(post, user)))
        {:error, :unauthorized} -> {:error, :forbidden}
        {:error, reason} -> {:error, {422, Polls.message(reason)}}
      end
    end
  end

  defp poll_json(view) do
    poll = view.poll

    %{
      kind: poll.kind,
      min_choices: poll.min_choices,
      max_choices: poll.max_choices,
      public: poll.public,
      closed: view.closed?,
      close_at: poll.close_at,
      options: Enum.map(poll.options, &%{id: &1.id, text: &1.text}),
      mine: view.mine,
      voters: view.voters,
      results: if(view.results?, do: %{counts: view.results.counts})
    }
  end

  defp render_post(post, user) do
    post = Repo.preload(post, :user)
    ThreadController.post_renderer([post], user).(post)
  end

  defp not_found(:ok), do: :ok
  defp not_found(_denied), do: {:error, :not_found}

  @doc """
  The post `id` and its thread, if `user` may read the thread and see the
  post exists (a reply awaiting approval only for its author and admins).
  """
  def fetch(id, user) do
    with id when is_integer(id) <- int(id),
         %Post{} = post <- Repo.get(Post, id),
         {:ok, thread} <- ThreadController.fetch(post.thread_id, user),
         false <- Post.queued?(post) and permit(user, :view_hidden_post, post) != :ok do
      {:ok, post, thread}
    else
      _missing_or_hidden -> {:error, :not_found}
    end
  end
end
