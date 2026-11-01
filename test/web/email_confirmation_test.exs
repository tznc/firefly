defmodule FirestormWeb.Web.EmailConfirmationTest do
  use FirestormWeb.Web.ConnCase, async: false
  use Bamboo.Test, shared: true

  alias FirestormWeb.{EmailConfirmation, Forums}
  alias FirestormWeb.Forums.User

  defp register(username \\ "newbie") do
    {:ok, user} =
      Forums.register_user(%{
        username: username,
        email: "#{username}@example.com",
        password: "s3cret-password"
      })

    user
  end

  defp assert_confirmation_sent(user) do
    assert_email_delivered_with(
      to: [nil: user.email],
      subject: "Confirm your email address for Firefly"
    )
  end

  test "registering emails a confirmation link", %{conn: conn} do
    conn
    |> visit(~p"/register")
    |> fill_in("Username", with: "newbie")
    |> fill_in("Email", with: "newbie@example.com")
    |> fill_in("Password", with: "s3cret-password")
    |> click_button("Create account")
    |> assert_has("#confirm-email-notice", text: "newbie@example.com")

    user = Forums.get_user_by_username("newbie")
    assert_confirmation_sent(user)
  end

  test "following the link confirms the address", %{conn: conn} do
    user = register()

    conn
    |> log_in_as(user)
    |> visit(~p"/confirm/#{EmailConfirmation.token(user)}")
    |> assert_has("#flash-info", text: "your email address is confirmed")
    |> refute_has("#confirm-email-notice")

    assert User.confirmed?(Forums.get_user!(user.id))
  end

  test "an invalid link is refused", %{conn: conn} do
    conn
    |> visit(~p"/confirm/not-a-token")
    |> assert_has("#flash-error", text: "invalid or has expired")
  end

  test "the notice resends the link", %{conn: conn} do
    user = register()

    conn
    |> log_in_as(user)
    |> visit(~p"/")
    |> click_button("Resend link")
    |> assert_has("#flash-info", text: "We sent a new confirmation link to newbie@example.com")

    assert_confirmation_sent(user)
  end

  test "unconfirmed users can't post", %{conn: conn} do
    user = register()
    thread = thread_fixture(category_fixture(), user_fixture())

    conn
    |> log_in_as(user)
    |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}/posts/new")
    |> fill_in("Body", with: "hello")
    |> click_button("Reply")
    |> assert_has("#flash-error", text: "Please confirm your email address before posting.")

    api =
      build_conn()
      |> put_req_header("authorization", "Bearer #{user.api_token}")
      |> post(~p"/api/v1/posts", post: %{body: "hello"}, thread_id: thread.id)

    assert json_response(api, 403)["error"] =~ "confirm your email"
  end

  test "changing your email sends a new confirmation link", %{conn: conn} do
    user = user_fixture()

    conn
    |> log_in_as(user)
    |> visit(~p"/users/#{user}/edit")
    |> fill_in("Email", with: "changed@example.com")
    |> click_button("Save")
    |> assert_has("#flash-info", text: "confirm the new address")

    user = Forums.get_user!(user.id)
    refute User.confirmed?(user)
    assert_confirmation_sent(user)
  end
end
