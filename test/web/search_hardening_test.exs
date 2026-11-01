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

    test "filtering by a muted category or tag shows its threads", %{reader: reader} do
      assert titles(Search.run(Search.parse("otp category:noise"), reader)) == ["Muted category"]
      assert titles(Search.run(Search.parse("otp", %{"tag" => "rant"}), reader)) == ["Muted tag"]
      # A muted thread in a category that isn't muted stays out.
      assert titles(Search.run(Search.parse("otp category:elixir"), reader)) == ["Kept"]
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
      # Day-long window: Hammer windows are clock-aligned (see rate_limit_test).
      limits = Keyword.put(config[:limits], :search, {2, 86_400_000})
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

      # Only the connected render searches, so each page load counts once.
      session
      |> visit(~p"/search?q=otp")
      |> assert_has("#search-results")
      |> visit(~p"/search?q=otp")
      |> assert_has("#search-results")
      |> visit(~p"/search?q=otp")
      |> assert_has("#search-rate-limited", text: "too often")
      |> refute_has("#search-results")
    end

    test "the static render neither searches nor counts", %{conn: conn, reader: reader} do
      conn = log_in_as(conn, reader)

      for _ <- 1..3 do
        html = conn |> get(~p"/search?q=otp") |> html_response(200)
        refute html =~ "search-results"
        refute html =~ "search-rate-limited"
      end

      conn |> visit(~p"/search?q=otp") |> assert_has("#search-results", text: "1 result")
    end

    test "behind a trusted proxy, visitors are limited by their forwarded IP", %{conn: conn} do
      trust(["10.0.0.0/8"])
      proxy = {10, 1, 2, 3}

      search = fn client ->
        %{conn | remote_ip: proxy}
        |> put_req_header("x-forwarded-for", "#{client}")
        |> get(~p"/api/v1/search?q=otp")
      end

      first = "203.0.113.#{rem(System.unique_integer([:positive]), 250)}"
      assert search.(first).status == 200
      assert search.(first).status == 200
      assert search.(first).status == 429
      # Another visitor behind the same proxy has their own allowance.
      assert search.("198.51.100.7").status == 200
    end
  end

  defp trust(proxies) do
    Application.put_env(:firestorm_web, FirestormWeb.Web.ClientIP, trusted_proxies: proxies)
    on_exit(fn -> Application.delete_env(:firestorm_web, FirestormWeb.Web.ClientIP) end)
  end

  describe "client IP" do
    alias FirestormWeb.Web.ClientIP

    test "X-Forwarded-For is ignored unless proxies are trusted" do
      assert ClientIP.resolve({1, 2, 3, 4}, ["5.6.7.8"]) == {1, 2, 3, 4}
    end

    test "only a trusted peer's header counts, read right to left" do
      trust(["10.0.0.0/8", "fd00::/8", "192.0.2.1"])

      # An untrusted peer can't claim another address.
      assert ClientIP.resolve({1, 2, 3, 4}, ["5.6.7.8"]) == {1, 2, 3, 4}
      assert ClientIP.resolve({10, 0, 0, 1}, ["5.6.7.8"]) == {5, 6, 7, 8}
      # Entries the client made up (left of the first untrusted hop) are skipped.
      assert ClientIP.resolve({10, 0, 0, 1}, ["9.9.9.9, 5.6.7.8", "192.0.2.1"]) == {5, 6, 7, 8}

      assert ClientIP.resolve({0xFD00, 0, 0, 0, 0, 0, 0, 1}, ["2001:db8::1"]) ==
               {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}

      # Garbage or only proxies: the closest trusted hop.
      assert ClientIP.resolve({10, 0, 0, 1}, ["junk"]) == {10, 0, 0, 1}
      assert ClientIP.resolve({10, 0, 0, 1}, ["10.0.0.2"]) == {10, 0, 0, 2}
      assert ClientIP.resolve({10, 0, 0, 1}, []) == {10, 0, 0, 1}
    end

    test "a bad trusted proxy entry is a configuration error" do
      trust(["10.0.0.0/33"])
      assert_raise ArgumentError, fn -> ClientIP.resolve({1, 2, 3, 4}, []) end
    end
  end
end
