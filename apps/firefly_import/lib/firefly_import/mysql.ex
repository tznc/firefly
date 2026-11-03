defmodule FireflyImport.MySQL do
  @moduledoc "Reading a MySQL or MariaDB source database (phpBB, vBulletin)."

  alias FireflyImport.SQL

  @doc """
  Connects to the database at `url` (`mysql://user:password@host/db`) and
  checks `table` is there: `{:ok, conn}` or `{:error, message}`.
  """
  def connect(nil, _table), do: {:error, "--source-url is required"}

  def connect(url, table) do
    opts = SQL.url_options(url) ++ [pool_size: 1, timeout: :infinity]

    with {:ok, conn} <- MyXQL.start_link(opts),
         {:ok, _} <- MyXQL.query(conn, "SELECT 1 FROM #{table} LIMIT 1") do
      {:ok, conn}
    else
      {:error, %{message: message}} -> {:error, message}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  @doc "Closes the connection."
  def close(conn) do
    GenServer.stop(conn)
    :ok
  end

  @doc "The rows of a query, as maps (column names as atom keys)."
  def query(conn, sql, params \\ []), do: conn |> MyXQL.query!(sql, params) |> SQL.maps()

  @doc "Whether the table has that column."
  def column?(conn, table, column) do
    query(
      conn,
      "SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?",
      [table, column]
    ) != []
  end

  @doc "Whether the table exists."
  def table?(conn, table) do
    query(
      conn,
      "SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?",
      [table]
    ) != []
  end

  @doc """
  The rows of `sql` page by page: it takes the last row's `key` (`?`, 0 at
  first) and the page size (`?`), and orders by `key`.
  """
  def paged(conn, sql, key) do
    SQL.paged(fn last, page ->
      query(conn, sql, [if(last, do: Map.fetch!(last, key), else: 0), page])
    end)
  end
end
