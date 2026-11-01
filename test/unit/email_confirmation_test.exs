defmodule FirestormWeb.EmailConfirmationTest do
  use FirestormWeb.DataCase, async: true

  alias FirestormWeb.{EmailConfirmation, Forums}
  alias FirestormWeb.Forums.User

  defp register do
    {:ok, user} =
      Forums.register_user(%{
        username: "newbie",
        email: "newbie@example.com",
        password: "s3cret-password"
      })

    user
  end

  test "registered users start unconfirmed; directly created users are confirmed" do
    refute User.confirmed?(register())

    {:ok, admin_made} = Forums.create_user(%{username: "x", name: "X", email: "x@example.com"})
    assert User.confirmed?(admin_made)
  end

  test "a confirmation token confirms the user" do
    user = register()
    assert {:ok, confirmed} = EmailConfirmation.confirm(EmailConfirmation.token(user))
    assert User.confirmed?(confirmed)
  end

  test "tokens are rejected when tampered with or issued for an old email" do
    user = register()
    token = EmailConfirmation.token(user)

    assert {:error, :invalid} = EmailConfirmation.confirm(token <> "x")

    {:ok, _} = Forums.update_user(user, %{email: "new@example.com"})
    assert {:error, :invalid} = EmailConfirmation.confirm(token)
  end

  test "changing the email address requires confirming it again" do
    {:ok, user} = Forums.confirm_user(register())

    {:ok, user} = Forums.update_user(user, %{name: "Newbie"})
    assert User.confirmed?(user)

    {:ok, user} = Forums.update_user(user, %{email: "new@example.com"})
    refute User.confirmed?(user)
  end
end
