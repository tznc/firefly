defmodule FirestormWeb.Web.PaginationHelpers do
  @moduledoc """
  Renders pagination links for a `Scrivener.Page`, using the Bootstrap v4
  markup (`ul.pagination > li.page-item > a.page-link`) our styles expect.

  Replaces the unmaintained `scrivener_html` package.
  """

  import Phoenix.HTML, only: [raw: 1]
  import PhoenixHTMLHelpers.Tag, only: [content_tag: 3]
  import PhoenixHTMLHelpers.Link, only: [link: 2]

  @distance 2

  @spec pagination_links(Plug.Conn.t(), Scrivener.Page.t()) :: Phoenix.HTML.safe()
  def pagination_links(_conn, %Scrivener.Page{total_pages: total}) when total <= 1, do: raw("")

  def pagination_links(conn, %Scrivener.Page{page_number: current, total_pages: total}) do
    items =
      [{"«", current - 1, current > 1}] ++
        Enum.map(page_window(current, total), &{Integer.to_string(&1), &1, true}) ++
        [{"»", current + 1, current < total}]

    content_tag(:nav, [],
      do: content_tag(:ul, Enum.map(items, &item(conn, current, &1)), class: "pagination")
    )
  end

  @doc false
  def page_window(current, total) do
    Enum.to_list(max(1, current - @distance)..min(total, current + @distance)//1)
  end

  defp item(_conn, _current, {_label, _page, false}), do: []

  defp item(conn, current, {label, page, true}) do
    class = if label == Integer.to_string(current), do: "page-item active", else: "page-item"
    content_tag(:li, link(label, to: page_url(conn, page), class: "page-link"), class: class)
  end

  defp page_url(conn, page) do
    query =
      conn.query_params
      |> Map.put("page", Integer.to_string(page))
      |> Plug.Conn.Query.encode()

    "#{conn.request_path}?#{query}"
  end
end
