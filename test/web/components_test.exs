defmodule FirestormWeb.Web.ForumComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias FirestormWeb.Web.ForumComponents

  describe "short_date/1" do
    test "formats as abbreviated month, day and two-digit year" do
      assert ForumComponents.short_date(~N[2017-07-03 12:00:00]) == "Jul 3, '17"
      assert ForumComponents.short_date(~N[2009-12-25 00:00:00.123456]) == "Dec 25, '09"
    end
  end

  describe "time_ago/1" do
    test "renders an ISO 8601 UTC <time> for the LocalTime hook" do
      html = render_component(&ForumComponents.time_ago/1, id: "t", at: ~N[2017-07-13 10:20:30])

      assert html =~ ~s(datetime="2017-07-13T10:20:30Z")
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ "2017-07-13T10:20:30Z</time>"
    end

    test "accepts a DateTime" do
      html = render_component(&ForumComponents.time_ago/1, id: "t", at: ~U[2017-07-13 10:20:30Z])
      assert html =~ ~s(datetime="2017-07-13T10:20:30Z")
    end
  end

  describe "category_color/1" do
    test "is a stable hue derived from the slug" do
      assert "oklch(55% 0.13 " <> hue = ForumComponents.category_color(%{slug: "elixir"})
      hue = hue |> String.trim_trailing(")") |> String.to_integer()
      assert hue in 0..359
      assert ForumComponents.category_color(%{slug: "elixir"}) == "oklch(55% 0.13 #{hue})"
    end

    test "uses the category's chosen color" do
      assert ForumComponents.category_color(%{slug: "elixir", color: "#3b82f6"}) == "#3b82f6"
    end
  end

  describe "pagination/1" do
    defp page(number, total), do: %Scrivener.Page{page_number: number, total_pages: total}

    test "renders nothing for a single page" do
      refute render_component(&ForumComponents.pagination/1, page: page(1, 1), path: "/users") =~
               "<nav"
    end

    test "renders page links, marking the current page" do
      html = render_component(&ForumComponents.pagination/1, page: page(2, 3), path: "/users")

      assert html =~ ~s(href="/users?page=1")
      assert html =~ ~s(href="/users?page=3")
      assert html =~ ~s(aria-current="page")
      assert html =~ "Previous page"
      assert html =~ "Next page"
    end

    test "omits previous on the first page and next on the last page" do
      first = render_component(&ForumComponents.pagination/1, page: page(1, 2), path: "/users")
      last = render_component(&ForumComponents.pagination/1, page: page(2, 2), path: "/users")

      refute first =~ "Previous page"
      assert first =~ "Next page"
      assert last =~ "Previous page"
      refute last =~ "Next page"
    end

    test "page_window/2 shows up to two pages either side of the current page" do
      assert ForumComponents.page_window(1, 10) == [1, 2, 3]
      assert ForumComponents.page_window(5, 10) == [3, 4, 5, 6, 7]
      assert ForumComponents.page_window(10, 10) == [8, 9, 10]
    end
  end
end
