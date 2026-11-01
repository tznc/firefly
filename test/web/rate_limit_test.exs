defmodule FirestormWeb.RateLimitTest do
  use FirestormWeb.Web.ConnCase, async: false

  alias FirestormWeb.{Forums, RateLimit}

  setup do
    config = Application.get_env(:firestorm_web, RateLimit)

    # Hammer uses fixed windows aligned to the clock: with a one-minute window
    # a test that runs across hh:mm:00 gets a fresh bucket halfway through and
    # flakes. A day-long window makes that practically impossible.
    day = 86_400_000

    Application.put_env(:firestorm_web, RateLimit,
      limits: [
        login: {3, day},
        login_ip: {1_000, day},
        register: {1, day},
        post: {2, day},
        upload: {1, day},
        like: {2, day}
      ]
    )

    on_exit(fn -> Application.put_env(:firestorm_web, RateLimit, config) end)
  end

  defp attempt(conn, username, password) do
    post(conn, "/auth/identity/callback", %{
      "user" => %{"username" => username, "password" => password}
    })
  end

  test "locks out password guessing for a username", %{conn: conn} do
    username = "victim#{System.unique_integer([:positive])}"

    {:ok, _} =
      Forums.register_user(%{
        username: username,
        email: "#{username}@example.com",
        password: "right-password"
      })

    for _ <- 1..3, do: attempt(conn, username, "wrong-password")

    # Even the right password is refused while locked out
    conn = attempt(conn, username, "right-password")
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "too often"
    refute get_session(conn, :current_user)
  end

  test "limits API logins too", %{conn: conn} do
    username = "api#{System.unique_integer([:positive])}"

    for _ <- 1..3 do
      post(conn, "/api/v1/auth/identity", %{
        "user" => %{"username" => username, "password" => "x"}
      })
    end

    conn =
      post(conn, "/api/v1/auth/identity", %{
        "user" => %{"username" => username, "password" => "x"}
      })

    assert json_response(conn, 429)["error"] =~ "too often"
  end

  test "limits registrations per client", %{conn: conn} do
    register = fn session, username ->
      session
      |> visit(~p"/register")
      |> fill_in("Username", with: username)
      |> fill_in("Email", with: "#{username}@example.com")
      |> fill_in("Password", with: "s3cret-password")
      |> click_button("Create account")
    end

    register.(conn, "first#{System.unique_integer([:positive])}")

    build_conn()
    |> register.("second")
    |> assert_has("#flash-error", text: "too often")

    refute Forums.get_user_by_username("second")
  end

  test "limits how fast a user can post", %{conn: conn} do
    user = user_fixture()
    thread = thread_fixture(category_fixture(), user)

    session =
      conn
      |> log_in_as(user)
      |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}/posts/new")

    session |> fill_in("Body", with: "one") |> click_button("Reply")

    conn
    |> log_in_as(user)
    |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}/posts/new")
    |> fill_in("Body", with: "two")
    |> click_button("Reply")

    conn
    |> log_in_as(user)
    |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}/posts/new")
    |> fill_in("Body", with: "three")
    |> click_button("Reply")
    |> assert_has("#flash-error", text: "too often")

    assert thread |> FirestormWeb.Repo.preload(:posts, force: true) |> Map.get(:posts) |> length() ==
             3
  end

  test "limits upload signatures through the API", %{conn: conn} do
    user = user_fixture()
    conn = put_req_header(conn, "authorization", "Bearer #{user.api_token}")
    upload = %{"filename" => "a.png", "mimetype" => "image/png"}

    assert conn |> post("/api/v1/upload_signature", upload: upload) |> json_response(201)
    assert conn |> post("/api/v1/upload_signature", upload: upload) |> json_response(429)
  end

  test "limits liking and unliking", %{conn: conn} do
    author = user_fixture()
    liker = user_fixture()
    thread = thread_fixture(category_fixture(), author)
    path = ~p"/categories/#{thread.category_id}/threads/#{thread}"
    [post] = FirestormWeb.Repo.preload(thread, :posts).posts

    conn
    |> log_in_as(liker)
    |> visit(path)
    |> click_button("Like post #{post.id}")
    |> click_button("Unlike post #{post.id}")
    |> click_button("Like post #{post.id}")
    |> assert_has("#flash-error", text: RateLimit.message())

    refute Forums.likers([post])[post.id]
  end
end
