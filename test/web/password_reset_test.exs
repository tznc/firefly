defmodule FirestormWeb.Web.PasswordResetTest do
  use FirestormWeb.Web.ConnCase, async: false
  use Bamboo.Test, shared: true

  alias FirestormWeb.{Forums, PasswordReset}

  setup do
    {:ok, user} =
      Forums.register_user(%{
        username: "newbie",
        email: "Newbie@Example.com",
        password: "old-password"
      })

    %{user: user}
  end

  test "the login page links to password reset", %{conn: conn} do
    conn
    |> visit(~p"/auth/identity")
    |> click_link("Forgot your password?")
    |> assert_path(~p"/reset-password")
  end

  test "requesting a reset emails a link (matching email case-insensitively)", %{conn: conn} do
    conn
    |> visit(~p"/reset-password")
    |> fill_in("Email", with: "newbie@example.com")
    |> click_button("Send reset link")
    |> assert_has("#flash-info", text: "we've sent it a link")

    assert_email_delivered_with(
      to: [nil: "Newbie@Example.com"],
      subject: "Reset your Firefly password"
    )
  end

  test "unknown emails get the same answer and no email", %{conn: conn} do
    conn
    |> visit(~p"/reset-password")
    |> fill_in("Email", with: "nobody@example.com")
    |> click_button("Send reset link")
    |> assert_has("#flash-info", text: "we've sent it a link")

    assert_no_emails_delivered()
  end

  test "accounts without a password (GitHub) get no reset email", %{conn: conn} do
    {:ok, _} =
      Forums.login_or_register_from_github(%{
        uid: 1,
        nickname: "octo",
        name: "Octo",
        email: "octo@example.com"
      })

    conn
    |> visit(~p"/reset-password")
    |> fill_in("Email", with: "octo@example.com")
    |> click_button("Send reset link")

    assert_no_emails_delivered()
  end

  test "a reset link sets a new password once and confirms the email", %{conn: conn, user: user} do
    token = PasswordReset.token(user)

    conn
    |> visit(~p"/reset-password/#{token}")
    |> fill_in("New password", with: "new-password")
    |> fill_in("Confirm new password", with: "new-password")
    |> click_button("Reset password")
    |> assert_path(~p"/auth/identity")
    |> assert_has("#flash-info", text: "Password reset.")

    assert {:ok, user} = Forums.authenticate_by_password("newbie", "new-password")
    assert {:error, _} = Forums.authenticate_by_password("newbie", "old-password")
    assert Forums.User.confirmed?(user)

    # Single use: the old link stops working once the password changed
    assert {:error, :invalid} = PasswordReset.verify(token)

    build_conn()
    |> visit(~p"/reset-password/#{token}")
    |> assert_path(~p"/reset-password")
    |> assert_has("#flash-error", text: "invalid or has expired")
  end

  test "the new password is validated", %{conn: conn, user: user} do
    conn
    |> visit(~p"/reset-password/#{PasswordReset.token(user)}")
    |> fill_in("New password", with: "short")
    |> fill_in("Confirm new password", with: "different")
    |> click_button("Reset password")
    |> assert_has("p", text: "should be at least 8 character(s)")
    |> assert_has("p", text: "does not match password")

    assert {:ok, _} = Forums.authenticate_by_password("newbie", "old-password")
  end

  test "tampered tokens are refused" do
    assert {:error, :invalid} = PasswordReset.verify("nope")
  end
end
