defmodule FireflyWeb.Plugs.Analytics do
  @moduledoc """
  Counts page views for `Firefly.Analytics`.

  As a plug (in the browser and API pipelines) it counts each request:
  page loads (`GET`) in the browser pipeline by kind, and their referrer
  domain, and every API request as `api`. A LiveView page is counted
  when it connects instead (by `FireflyWeb.UserAuth`), which also counts
  navigating inside the live app (no request) but not reconnects; only
  crawlers, which don't connect, are counted here for those.

  Requests with `DNT: 1` or `Sec-GPC: 1` count in the totals only;
  `live_session/1` passes that on to LiveViews (topic views and link
  clicks skip them).
  """

  @behaviour Plug

  import Plug.Conn

  alias Firefly.Analytics

  @impl Plug
  def init(kind), do: kind

  @impl Plug
  def call(conn, :api) do
    if Analytics.enabled?(), do: Analytics.page_view("api")
    conn
  end

  def call(%Plug.Conn{method: "GET"} = conn, :browser) do
    if Analytics.enabled?() do
      user_agent = conn |> get_req_header("user-agent") |> List.first()
      kind = Analytics.kind(conn.assigns[:current_user], user_agent)
      if kind == "crawler" or not live?(conn), do: Analytics.page_view(kind)

      if kind != "crawler" and not do_not_track?(conn),
        do: Analytics.referrer(conn |> get_req_header("referer") |> List.first(), conn.host)
    end

    conn
  end

  def call(conn, :browser), do: conn

  # The router marks LiveView routes before the pipeline runs.
  defp live?(conn), do: Map.has_key?(conn.private, :phoenix_live_view)

  @doc "Whether the request asks not to be tracked."
  def do_not_track?(conn),
    do: get_req_header(conn, "dnt") == ["1"] or get_req_header(conn, "sec-gpc") == ["1"]

  @doc """
  The LiveView session's analytics flags (see `live_session` in the
  router): `"analytics_dnt"`.
  """
  def live_session(conn), do: %{"analytics_dnt" => do_not_track?(conn)}
end
