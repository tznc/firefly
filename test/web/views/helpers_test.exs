defmodule FirestormWeb.Web.HelpersTest do
  use ExUnit.Case, async: true

  import Phoenix.HTML, only: [safe_to_string: 1]
  alias FirestormWeb.Web.{PaginationHelpers, TagHelpers, ViewHelpers}

  describe "ViewHelpers.short_date/1" do
    test "formats as abbreviated month, day and two-digit year" do
      assert ViewHelpers.short_date(~N[2017-07-03 12:00:00]) == "Jul 3, '17"
      assert ViewHelpers.short_date(~N[2009-12-25 00:00:00.123456]) == "Dec 25, '09"
    end
  end

  describe "TagHelpers.time_abbr/1" do
    test "wraps an ISO 8601 UTC time in an abbr tag" do
      html = ~N[2017-07-13 10:20:30] |> TagHelpers.time_abbr() |> safe_to_string()

      assert html ==
               ~s(<abbr class="time" title="2017-07-13T10:20:30Z">2017-07-13T10:20:30Z</abbr>)
    end

    test "accepts a DateTime" do
      html = ~U[2017-07-13 10:20:30Z] |> TagHelpers.time_abbr() |> safe_to_string()
      assert html =~ ~s(title="2017-07-13T10:20:30Z")
    end
  end

  describe "PaginationHelpers.pagination_links/2" do
    defp conn(query \\ %{}) do
      Plug.Test.conn(:get, "/users?" <> URI.encode_query(query)) |> Plug.Conn.fetch_query_params()
    end

    defp page(number, total), do: %Scrivener.Page{page_number: number, total_pages: total}

    test "renders nothing for a single page" do
      assert PaginationHelpers.pagination_links(conn(), page(1, 1)) |> safe_to_string() == ""
    end

    test "renders page links, marking the current page active" do
      html = PaginationHelpers.pagination_links(conn(), page(2, 3)) |> safe_to_string()

      assert html =~ ~s(<ul class="pagination">)

      assert html =~
               ~s(<li class="page-item active"><a class="page-link" href="/users?page=2">2</a></li>)

      assert html =~ ~s(<a class="page-link" href="/users?page=1">«</a>)
      assert html =~ ~s(<a class="page-link" href="/users?page=3">»</a>)
    end

    test "omits previous on the first page and next on the last page" do
      first = PaginationHelpers.pagination_links(conn(), page(1, 2)) |> safe_to_string()
      last = PaginationHelpers.pagination_links(conn(), page(2, 2)) |> safe_to_string()

      refute first =~ "«"
      assert first =~ "»"
      assert last =~ "«"
      refute last =~ "»"
    end

    test "preserves other query params" do
      html =
        PaginationHelpers.pagination_links(conn(%{"q" => "x", "page" => "1"}), page(1, 2))
        |> safe_to_string()

      assert html =~ ~s(href="/users?page=2&amp;q=x")
    end

    test "page_window/2 shows up to two pages either side of the current page" do
      assert PaginationHelpers.page_window(1, 10) == [1, 2, 3]
      assert PaginationHelpers.page_window(5, 10) == [3, 4, 5, 6, 7]
      assert PaginationHelpers.page_window(10, 10) == [8, 9, 10]
    end
  end
end
