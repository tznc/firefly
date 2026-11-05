defmodule FireflyWeb.BotChallengeTest do
  # Turns the bot challenge on (application env).
  use FireflyWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias Firefly.{Accounts, Security}
  alias Firefly.Security.Challenge

  @moduletag :capture_log
  @strong "tangerine-otter-galaxy"

  setup do
    previous = Application.get_env(:firefly, Challenge)
    Application.put_env(:firefly, Challenge, enabled: true)
    on_exit(fn -> Application.put_env(:firefly, Challenge, previous) end)
  end

  # What the BotChallenge hook puts in the form, for the challenge on the page.
  defp answer(view) do
    challenge =
      view
      |> element("[phx-hook=BotChallenge]")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-challenge")
      |> hd()
      |> JSON.decode!()

    %Altcha.V1.Solution{number: number} =
      Altcha.V1.solve_challenge(
        challenge["challenge"],
        challenge["salt"],
        :sha256,
        challenge["maxnumber"]
      )

    challenge
    |> Map.delete("maxnumber")
    |> Map.put("number", number)
    |> JSON.encode!()
    |> Base.encode64()
  end

  defp challenge_id(view) do
    view
    |> element("[phx-hook=BotChallenge]")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("id")
  end

  defp registration(username),
    do: %{"username" => username, "email" => "#{username}@example.com", "password" => @strong}

  describe "registration" do
    test "needs the answer, then logs in without another", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/register")
      assert html =~ "Checking that you&#39;re not a bot"
      assert html =~ ~s(role="status")

      html =
        render_submit(view, "save", %{"user" => registration("robot"), "bot_challenge" => ""})

      assert html =~ "Wait a moment for the check"
      refute Accounts.get_user_by_username("robot")

      first = challenge_id(view)

      html =
        render_submit(view, "save", %{"user" => registration("robot"), "bot_challenge" => "x"})

      assert html =~ "didn&#39;t pass"
      refute Accounts.get_user_by_username("robot")
      assert challenge_id(view) != first

      form = %{"user" => registration("human"), "bot_challenge" => answer(view)}
      render_submit(view, "save", form)
      assert %{id: id} = Accounts.get_user_by_username("human")

      # The form then posts to the login callback with a token for the new account.
      token =
        view
        |> element("#registration-form input[name=registered]")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("value")
        |> hd()

      for _ <- 1..3, do: Security.record("login.failure", %Accounts.User{id: id})
      assert Challenge.required_for_login?("human", {127, 0, 0, 1})

      conn =
        post(build_conn(), ~p"/auth/identity/callback", %{
          "user" => %{"username" => "human", "password" => @strong},
          "registered" => token
        })

      assert redirected_to(conn) == "/"

      # Another account's token doesn't do.
      other = user_fixture()
      for _ <- 1..3, do: Security.record("login.failure", other)

      conn =
        post(build_conn(), ~p"/auth/identity/callback", %{
          "user" => %{"username" => other.username, "password" => @strong},
          "registered" => token
        })

      assert redirected_to(conn) == "/auth/identity?challenge=1"
    end
  end

  test "password reset and login link requests need the answer", %{conn: conn} do
    {:ok, user} = Accounts.register_user(registration("reader"))

    {:ok, view, _html} = live(conn, ~p"/reset-password")
    html = render_submit(view, "send", %{"user" => %{"email" => user.email}})
    assert html =~ "Wait a moment for the check"
    assert_no_email_sent()

    render_submit(view, "send", %{
      "user" => %{"email" => user.email},
      "bot_challenge" => answer(view)
    })

    assert_email_sent()

    # A confirmed account gets login links.
    user = user_fixture()
    {:ok, view, _html} = live(build_conn(), ~p"/login/email")

    html =
      render_submit(view, "send", %{"login" => %{"email" => user.email}, "bot_challenge" => "x"})

    assert html =~ "didn&#39;t pass"
    assert_no_email_sent()

    render_submit(view, "send", %{
      "login" => %{"email" => user.email},
      "bot_challenge" => answer(view)
    })

    assert_email_sent()
  end

  describe "password logins" do
    setup do
      {:ok, user} =
        Accounts.register_user(%{
          username: "member",
          email: "member@example.com",
          password: @strong
        })

      {:ok, user: user}
    end

    defp fail_logins(user), do: for(_ <- 1..3, do: Security.record("login.failure", user))

    test "need it only after failures", %{conn: conn, user: user} do
      {:ok, view, html} = live(conn, ~p"/auth/identity")
      refute html =~ "BotChallenge"

      params = %{"user" => %{"username" => "member", "password" => @strong}}
      render_submit(view, "submit", params)
      assert_redirect_trigger(view)

      fail_logins(user)
      {:ok, view, _html} = live(build_conn(), ~p"/auth/identity")
      html = render_submit(view, "submit", params)
      assert html =~ "Wait a moment for the check"
      assert html =~ "BotChallenge"
      refute trigger?(view)

      render_submit(view, "submit", Map.put(params, "bot_challenge", answer(view)))
      assert trigger?(view)
    end

    test "the callback checks the answer", %{user: user} do
      fail_logins(user)
      params = %{"user" => %{"username" => "member", "password" => @strong}}

      conn = post(build_conn(), ~p"/auth/identity/callback", params)
      assert redirected_to(conn) == "/auth/identity?challenge=1"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "didn't pass"

      {:ok, view, html} = live(build_conn(), ~p"/auth/identity?challenge=1")
      assert html =~ "BotChallenge"

      conn =
        post(
          build_conn(),
          ~p"/auth/identity/callback",
          Map.put(params, "bot_challenge", answer(view))
        )

      assert redirected_to(conn) == "/"
    end
  end

  defp trigger?(view), do: render(view) =~ ~s(phx-trigger-action)
  defp assert_redirect_trigger(view), do: assert(trigger?(view))
end
