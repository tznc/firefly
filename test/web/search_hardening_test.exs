defmodule FirestormWeb.Web.SearchHardeningTest do
  use FirestormWeb.Web.ConnCase, async: false

  alias FirestormWeb.{Forums, RateLimit, Search}
  alias FirestormWeb.Forums.Subscriptions

  setup do
    alice = user_fixture(%{username: "alice"})
    elixir = category_fixture("Elixir")
    noise = category_fixture("Noise")

    thread_fixture(elixir, alice, %{title: "Kept", body: "otp everywhere"})
    muted_thread = thread_fixture(elixir, alice, %{title: "Muted thread", body: "otp again"})
    thread_fixture(noise, alice, %{title: "Muted category", body: "otp noise"})
    thread_fixture(elixir, alice, %{title: "Muted tag", body: "otp tagged", tags: "rant"})

    reader = user_fixture(%{username: "reader"})
    {:ok, _} = Subscriptions.set_thread_level(reader, muted_thread, "muted")
    {:ok, _} = Subscriptions.set_category_level(reader, noise, "muted")
    {:ok, _} = Subscriptions.set_tag_level(reader, Forums.get_tag!("rant"), "muted")

    %{reader: reader}
  end

  defp titles(page), do: page.entries |> Enum.map(& &1.thread.title) |> Enum.sort()

  describe "muted threads" do
    test "are left out of the user's results unless included", %{reader: reader} do
      assert titles(Search.run(Search.parse("otp"), reader)) == ["Kept"]

      assert titles(Search.run(Search.parse("otp", %{"muted" => "include"}), reader)) ==
               ["Kept", "Muted category", "Muted tag", "Muted thread"]

      # Others' mutes don't matter.
      assert length(Search.run(Search.parse("otp"), nil).entries) == 4
    end

    test "the search page has an Include muted toggle", %{conn: conn, reader: reader} do
      conn
      |> log_in_as(reader)
      |> visit(~p"/search?q=otp")
      |> assert_has("#search-results", text: "1 result")
      |> check("Include muted")
      |> submit()
      |> assert_has("#search-results", text: "4 results")

      conn |> visit(~p"/search?q=otp") |> refute_has("label", text: "Include muted")
    end
  end

  describe "rate limiting" do
    setup do
      config = Application.get_env(:firestorm_web, RateLimit)
      limits = Keyword.put(config[:limits], :search, {2, 60_000})
      Application.put_env(:firestorm_web, RateLimit, limits: limits)
      on_exit(fn -> Application.put_env(:firestorm_web, RateLimit, config) end)
    end

    test "the API limits visitors per IP and users per user", %{conn: conn, reader: reader} do
      ip = {10, 0, 0, rem(System.unique_integer([:positive]), 250)}
      search = fn conn -> get(%{conn | remote_ip: ip}, ~p"/api/v1/search?q=otp") end

      assert search.(conn).status == 200
      assert search.(conn).status == 200
      assert json_response(search.(conn), 429)["error"] =~ "too often"

      # A logged-in user has their own allowance, wherever they search from.
      authed = put_req_header(conn, "authorization", "Bearer #{reader.api_token}")
      assert search.(authed).status == 200
    end

    test "the search page says so instead of showing results", %{conn: conn, reader: reader} do
      session = conn |> log_in_as(reader)

      # Static render and live connection: two searches.
      session
      |> visit(~p"/search?q=otp")
      |> assert_has("#search-results")
      |> visit(~p"/search?q=otp")
      |> assert_has("#search-rate-limited", text: "too often")
      |> refute_has("#search-results")
    end
  end
end
