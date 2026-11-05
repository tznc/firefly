defmodule FireflyWeb.E2ECase do
  @moduledoc """
  End-to-end tests that drive a real browser (Chromium via Playwright)
  against the running test server, using `PhoenixTest.Playwright`.

  Tagged `:e2e`; run only these with `mix test --only e2e`.
  """
  use ExUnit.CaseTemplate

  using opts do
    quote do
      use PhoenixTest.Playwright.Case, unquote(opts)
      use FireflyWeb, :verified_routes

      import FireflyWeb.E2ECase
      import Firefly.DataCase, only: [run_notifications: 0]

      @moduletag :e2e
    end
  end

  import PhoenixTest

  alias Firefly.{Accounts, Groups}

  @password "s3cret-password"

  @doc "Creates a confirmed basic user (trust level 1) who can log in with `@password`."
  def member_fixture(username) do
    {:ok, user} =
      Accounts.register_user(%{
        username: username,
        email: "#{username}@example.com",
        password: @password
      })

    {:ok, user} = Accounts.confirm_user(user)
    # Past the new-user stage (see Firefly.TrustLevels), like most members.
    Firefly.Repo.update!(Ecto.Changeset.change(user, trust_level: 1))
  end

  @doc "Creates a member with the admin role."
  def admin_fixture(username) do
    user = member_fixture(username)
    {:ok, role} = Groups.create_role("admin")
    {:ok, _} = Groups.add_role(user, role)
    user
  end

  @doc """
  Opens a second, independent browser session (its own cookies) in the same
  test, sharing the test's database transaction. Use it for multi-user flows.
  """
  def another_browser(context) do
    config =
      context
      |> Map.take(PhoenixTest.Playwright.Config.setup_keys())
      |> PhoenixTest.Playwright.Config.validate!()

    PhoenixTest.Playwright.Case.new_session(config, context)
  end

  @doc """
  Logs in through the username/password form.

  `visit/2` returns once the page has loaded, not once its LiveView has
  joined. Typed into before that, the form is re-rendered on join with the
  server's (empty) values and the login goes out blank, so this waits for
  the connection first. Success is then checked on what a logged-in page
  always shows (the Account menu), not on the flash.
  """
  def log_in(session, username, password \\ @password) do
    session
    |> visit("/auth/identity")
    |> assert_has("[data-phx-main].phx-connected")
    |> fill_in("Username", with: username)
    |> fill_in("Password", with: password)
    |> click_button("Log in")
    |> assert_path("/")
    |> assert_has("nav a", text: "Your profile")
  end
end
