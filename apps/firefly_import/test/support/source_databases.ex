defmodule FireflyImport.SourceDatabases do
  @moduledoc "Source databases for importer tests, made from SQL fixtures."

  # Test support: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]

  @doc """
  (Re)creates the PostgreSQL database `name` on the test database's server,
  runs the statements in `sql_path` in it, and returns its URL.
  """
  def postgres(name, sql_path) do
    config = Firefly.Repo.config()
    opts = Keyword.take(config, [:hostname, :port, :username, :password])

    with_conn(opts ++ [database: "postgres"], fn conn ->
      Postgrex.query!(conn, ~s{DROP DATABASE IF EXISTS "#{name}" WITH (FORCE)}, [])
      Postgrex.query!(conn, ~s{CREATE DATABASE "#{name}"}, [])
    end)

    with_conn(opts ++ [database: name], fn conn ->
      for statement <- statements(sql_path), do: Postgrex.query!(conn, statement, [])
    end)

    "postgres://#{opts[:username]}:#{opts[:password]}@#{opts[:hostname]}:#{opts[:port] || 5432}/#{name}"
  end

  @doc "The SQL file's statements (each ends with a semicolon at the end of a line)."
  def statements(sql_path) do
    sql_path
    |> File.read!()
    |> String.split(~r/;\s*\n/)
    |> Enum.map(&strip_comments/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp strip_comments(statement) do
    statement
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(String.trim(&1), "--"))
    |> Enum.join("\n")
    |> String.trim()
  end

  defp with_conn(opts, fun) do
    {:ok, conn} = Postgrex.start_link(opts ++ [pool_size: 1])

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end
end
