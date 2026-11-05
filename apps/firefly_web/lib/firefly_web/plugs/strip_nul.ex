defmodule FireflyWeb.Plugs.StripNul do
  @moduledoc """
  Strips NUL characters from everything a request sends (see
  `Firefly.Text`): the query, the parsed body (forms, JSON, the API,
  webhooks and inbound email) and the path. Plugged right after
  `Plug.Parsers`, so every controller and LiveView's first render sees clean
  params.

  The router decodes the path itself, after this, so a NUL in the path is
  still `%00` here: that is what's taken out of `path_info`.
  """

  @behaviour Plug

  alias Firefly.Text

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    %{
      conn
      | path_info: Enum.map(conn.path_info, &String.replace(&1, "%00", "")),
        path_params: Text.strip_nul(conn.path_params),
        query_params: Text.strip_nul(conn.query_params),
        body_params: Text.strip_nul(conn.body_params),
        params: Text.strip_nul(conn.params)
    }
  end
end
