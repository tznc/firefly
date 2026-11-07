defmodule FireflyWeb.E2E.BotChallengeTest do
  # Turns the bot challenge on (application env, read by the test server).
  use FireflyWeb.E2ECase, async: false

  alias Firefly.{Accounts, Security}
  alias Firefly.Security.Challenge

  setup do
    previous = Application.get_env(:firefly, Challenge)
    Application.put_env(:firefly, Challenge, enabled: true)
    on_exit(fn -> Application.put_env(:firefly, Challenge, previous) end)
  end

  test "the browser answers the proof of work, and the member registers", %{conn: conn} do
    conn
    |> visit("/register")
    |> assert_has("[data-phx-main].phx-connected")
    |> fill_in("Username", with: "newbie")
    |> fill_in("Email", with: "newbie@example.com")
    |> fill_in("Password", with: "s3cret-password-otter")
    |> assert_has("[role=status]", text: "Checked: you can go on.")
    |> click_button("Create account")
    |> assert_has("#flash-info", text: "Successfully authenticated.")
    |> assert_has("nav a", text: "Your profile")

    assert Accounts.get_user_by_username("newbie")
  end

  test "a login after failures waits for the check", %{conn: conn} do
    alice = member_fixture("alice")
    for _ <- 1..3, do: Security.record("login.failure", alice)

    conn
    |> visit("/auth/identity")
    |> assert_has("[data-phx-main].phx-connected")
    |> fill_in("Username", with: "alice")
    |> fill_in("Password", with: "s3cret-password")
    |> click_button("Log in")
    |> assert_has("#flash-error", text: "Wait a moment for the check")
    |> assert_has("[role=status]", text: "Checked: you can go on.")
    |> click_button("Log in")
    |> assert_path("/")
    |> assert_has("nav a", text: "Your profile")
  end
end
