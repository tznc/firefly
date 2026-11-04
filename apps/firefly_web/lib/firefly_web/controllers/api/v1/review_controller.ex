defmodule FireflyWeb.Api.V1.ReviewController do
  @moduledoc """
  The review queue (admins; `admin` scope): posts with pending flags and
  posts awaiting approval, and deciding them as `/staff/review` does.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.Repo
  alias Firefly.Discussion.Post
  alias Firefly.Moderation.Review
  alias FireflyWeb.Api.Pagination
  alias FireflyWeb.Api.V1.PostJSON

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "admin")
  plug(:reviewer)

  def index(conn, params) do
    admin = current_user(conn)
    flagged = Enum.map(Review.flagged_posts(), &{:flagged, &1})
    queued = Enum.map(Review.queued_posts(), &{:queued, &1})

    Pagination.render(conn, flagged ++ queued, params, fn {kind, post} ->
      %{
        kind: kind,
        post: PostJSON.full(post, nil, admin, %{}),
        thread_id: post.thread_id,
        thread_title: post.thread.title,
        flags:
          if(kind == :flagged,
            do: Enum.map(post.flags, &%{reason: &1.reason, note: &1.note, user_id: &1.user_id}),
            else: []
          )
      }
    end)
  end

  @doc """
  `POST /review/posts/:id/:decision`: `agree` (with `action`: `hide`, the
  default, or `delete`), `disagree`, `defer`, `approve` or `reject` (with
  a `reason`).
  """
  def decide(conn, %{"id" => id, "decision" => decision} = params) do
    admin = current_user(conn)

    with id when is_integer(id) <- int(id),
         %Post{} = post <- Repo.get(Post, id),
         {:ok, _} <- decide(decision, post, admin, params) do
      no_content(conn)
    else
      {:error, reason} when reason in [:no_pending_flags, :not_queued, :reason_required] ->
        {:error, {422, Review.message(reason)}}

      other ->
        other
    end
  end

  defp decide("agree", post, admin, params),
    do: Review.agree(post, admin, if(params["action"] == "delete", do: :delete, else: :hide))

  defp decide("disagree", post, admin, _params), do: Review.disagree(post, admin)
  defp decide("defer", post, admin, _params), do: Review.defer(post, admin)
  defp decide("approve", post, admin, _params), do: Review.approve(post, admin)
  defp decide("reject", post, admin, params), do: Review.reject(post, admin, params["reason"])
  defp decide(_other, _post, _admin, _params), do: {:error, :not_found}

  defp reviewer(conn, _opts) do
    case permit(current_user(conn), :review) do
      :ok -> conn
      error -> conn |> FireflyWeb.Api.V1.FallbackController.call(error) |> halt()
    end
  end
end
