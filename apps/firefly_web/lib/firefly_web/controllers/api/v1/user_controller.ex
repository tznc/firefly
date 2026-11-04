defmodule FireflyWeb.Api.V1.UserController do
  @moduledoc """
  Members: the directory, profiles and activity (as their pages show
  them, so hidden profiles stay hidden), and (admins) silencing and
  suspending.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.{Accounts, Directory, Discussion}
  alias Firefly.Accounts.{Profiles, User}
  alias Firefly.Moderation.Penalties
  alias FireflyWeb.Api.Pagination
  alias FireflyWeb.Api.V1.{PostJSON, UserJSON}

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "read" when action in [:index, :show, :posts])
  plug(:require_scope, "admin" when action == :penalty)

  def index(conn, params) do
    Pagination.render_page(
      conn,
      params,
      &Directory.page(params |> Map.take(~w(period order asc name)) |> Map.put("page", &1)),
      fn %{user: user, stats: stats} ->
        user
        |> UserJSON.data()
        |> Map.put(
          :stats,
          Map.take(stats, Enum.map(Directory.columns(), &String.to_existing_atom/1))
        )
      end
    )
  end

  def show(conn, %{"username" => username}) do
    viewer = current_user(conn)

    with {:ok, user} <- fetch(username),
         true <- Profiles.visible?(user, viewer) || {:error, :not_found} do
      ok(conn, UserJSON.profile(user))
    end
  end

  def posts(conn, %{"username" => username} = params) do
    viewer = current_user(conn)
    filter = if params["filter"] in Profiles.activity_filters(), do: params["filter"], else: "all"

    with {:ok, user} <- fetch(username),
         true <- Profiles.activity_visible?(user, viewer) || {:error, :not_found} do
      Pagination.render_page(
        conn,
        params,
        &Discussion.user_posts(user, viewer, %{page: &1, filter: filter}),
        &Map.put(PostJSON.full(&1, nil, viewer, %{}), :thread_title, &1.thread.title)
      )
    end
  end

  @doc """
  `POST /users/:username/silence|suspend` (`duration`, `until`, `reason`;
  see `Firefly.Moderation.Penalties.penalize/4`) and `DELETE` to lift it.
  """
  def penalty(%{method: "DELETE"} = conn, %{"username" => username, "kind" => kind})
      when kind in ["silence", "suspend"] do
    admin = current_user(conn)

    with {:ok, user} <- fetch(username),
         :ok <- permit(admin, :lift_penalty, user),
         {:ok, user} <- Penalties.lift(String.to_existing_atom(kind), user, admin) do
      ok(conn, penalty_json(user))
    end
  end

  def penalty(conn, %{"username" => username, "kind" => kind} = params)
      when kind in ["silence", "suspend"] do
    admin = current_user(conn)

    with {:ok, user} <- fetch(username),
         :ok <- permit(admin, :penalize_user, user),
         {:ok, user} <- penalize(String.to_existing_atom(kind), user, admin, params) do
      ok(conn, penalty_json(user))
    end
  end

  def penalty(_conn, _params), do: {:error, :not_found}

  defp penalize(kind, user, admin, params) do
    case Penalties.penalize(kind, user, admin, Map.take(params, ~w(duration until reason))) do
      {:error, reason} when is_atom(reason) -> {:error, {422, Penalties.message(reason)}}
      result -> result
    end
  end

  defp penalty_json(user) do
    user
    |> UserJSON.data()
    |> Map.merge(
      Map.take(user, [:silenced_until, :silence_reason, :suspended_until, :suspend_reason])
    )
  end

  defp fetch(username) do
    case Accounts.get_user_by_username(username) do
      %User{deleted_at: nil} = user -> {:ok, user}
      _missing_or_deleted -> {:error, :not_found}
    end
  end
end
