defmodule FireflyImport.SQL do
  @moduledoc """
  Reading a source's SQL database in pages, for the importers that read
  one (Discourse's PostgreSQL, phpBB's and vBulletin's MySQL).
  """

  @page 1_000

  @doc """
  A stream of the rows `query` returns, page by page: `query` gets the
  last row of the previous page (nil at first) and the page size, and
  returns the next page's rows (maps), in a stable order; `key` gives a
  row's position in it (passed back through the last row).
  """
  def paged(query, page \\ @page) do
    Stream.resource(
      fn -> {nil, false} end,
      fn
        {_last, true} ->
          {:halt, nil}

        {last, false} ->
          case query.(last, page) do
            [] -> {:halt, nil}
            rows -> {rows, {List.last(rows), length(rows) < page}}
          end
      end,
      fn _ -> :ok end
    )
  end

  @doc "A result's rows as maps with atom keys (the source's column names)."
  def maps(%{columns: columns, rows: rows}) do
    keys = Enum.map(columns, &String.to_atom/1)
    Enum.map(rows || [], &Map.new(Enum.zip(keys, &1)))
  end

  @doc """
  Connection options from a database URL
  (`scheme://user:password@host:port/database`, `?ssl=true` for TLS).
  """
  def url_options(url) do
    uri = URI.parse(url)
    {username, password} = userinfo(uri.userinfo)
    query = URI.decode_query(uri.query || "")

    [
      hostname: uri.host || "localhost",
      username: username,
      password: password,
      database: String.trim_leading(uri.path || "", "/"),
      ssl: query["ssl"] in ~w(true require)
    ]
    |> then(&if uri.port, do: Keyword.put(&1, :port, uri.port), else: &1)
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp userinfo(nil), do: {nil, nil}

  defp userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [user, password] -> {URI.decode(user), URI.decode(password)}
      [user] -> {URI.decode(user), nil}
    end
  end
end
