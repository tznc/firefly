defmodule FireflyWeb.Api.Pagination do
  @moduledoc """
  Cursor pagination for API lists: `limit` (default #{30}, at most #{100})
  and an opaque `cursor` from the previous page's `meta.next_cursor`
  (null on the last page). Lists answer
  `{"data": [...], "meta": {"limit": ..., "next_cursor": ...}}`.

  Cursors are positions in the list as the context orders it, or, for
  streams that only grow at one end (chat), an id to continue before.
  """
  import Phoenix.Controller, only: [json: 2]

  @default 30
  @max 100

  @doc "The page size `params` ask for."
  def limit(params) do
    case Integer.parse(to_string(params["limit"] || "")) do
      {n, ""} when n > 0 -> min(n, @max)
      _none -> @default
    end
  end

  @doc "The position `params[\"cursor\"]` points at (0 without one; nil when it's invalid)."
  def offset(params), do: decode(params["cursor"], "o", 0)

  @doc "The id `params[\"cursor\"]` continues before (nil without one)."
  def before_id(params), do: decode(params["cursor"], "b", nil)

  defp decode(nil, _kind, default), do: default
  defp decode("", _kind, default), do: default

  defp decode(cursor, kind, _default) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [^kind, value] <- String.split(decoded, ":", parts: 2),
         {n, ""} when n >= 0 <- Integer.parse(value) do
      n
    else
      _invalid -> :invalid
    end
  end

  @doc """
  Renders a page of a list the context pages itself (a `Scrivener.Page`,
  fixed page size: `limit` is the context's): `fetch` takes the page
  number.
  """
  def render_page(conn, params, fetch, fun) do
    case decode(params["cursor"], "p", 1) do
      :invalid ->
        FireflyWeb.Api.Problem.send(conn, 400, "The cursor is invalid.")

      number ->
        page = fetch.(max(number, 1))

        next =
          if page.page_number < page.total_pages,
            do: Base.url_encode64("p:#{page.page_number + 1}", padding: false)

        json(conn, %{
          data: Enum.map(page.entries, fun),
          meta: %{limit: page.page_size, next_cursor: next}
        })
    end
  end

  @doc "A cursor continuing at `offset`."
  def offset_cursor(offset), do: Base.url_encode64("o:#{offset}", padding: false)

  @doc "A cursor continuing before message `id`."
  def before_cursor(id), do: Base.url_encode64("b:#{id}", padding: false)

  @doc """
  Renders one page of `entries`: either a list (the page is cut from it),
  or a function of `(offset, limit)` returning up to `limit` entries from
  `offset` (it's asked for one more, to know whether a next page exists).
  `fun` renders each entry.
  """
  def render(conn, entries, params, fun) do
    limit = limit(params)

    case offset(params) do
      :invalid ->
        FireflyWeb.Api.Problem.send(conn, 400, "The cursor is invalid.")

      offset ->
        fetched =
          if is_function(entries, 2),
            do: entries.(offset, limit + 1),
            else: entries |> Enum.drop(offset) |> Enum.take(limit + 1)

        {page, rest} = Enum.split(fetched, limit)
        next = if rest != [], do: offset_cursor(offset + limit)

        json(conn, %{data: Enum.map(page, fun), meta: %{limit: limit, next_cursor: next}})
    end
  end
end
