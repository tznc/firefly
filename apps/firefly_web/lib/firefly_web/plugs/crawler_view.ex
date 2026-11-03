defmodule FireflyWeb.Plugs.CrawlerView do
  @moduledoc """
  Serves crawlers a topic's plain, paginated page (see
  `FireflyWeb.CrawlerController`) instead of the LiveView.

  A crawler is one that says so in its `User-Agent`
  (`Firefly.Analytics.crawler?/1`, the same list the traffic counts use);
  a request without one is left alone, unlike in the counts, since it's
  as likely a client that will run the LiveView. Only a `GET` of a
  topic's path is handed over: everything else, and every reader with a
  browser, gets the LiveView as before.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    if crawler?(conn), do: serve(conn), else: conn
  end

  def call(conn, _opts), do: conn

  defp serve(%{path_info: ["categories", _category_id, "threads", _id]} = conn) do
    conn
    |> FireflyWeb.CrawlerController.call(FireflyWeb.CrawlerController.init(:thread))
    |> halt()
  end

  defp serve(conn), do: conn

  defp crawler?(conn) do
    case get_req_header(conn, "user-agent") do
      [agent | _] -> String.trim(agent) != "" and Firefly.Analytics.crawler?(agent)
      [] -> false
    end
  end
end
