defmodule FireflyWeb.AnalyticsController do
  @moduledoc """
  Link click beacons: the post body's script (the `Highlight` hook) sends
  `post_id` and `url` with `navigator.sendBeacon` when a reader follows an
  outbound link, so links aren't rewritten through a redirect. Counted by
  `Firefly.Analytics.link_click/2` unless analytics are off or the browser
  asks not to be tracked. Always answers 204: there's nothing to tell.
  """
  use FireflyWeb, :controller

  alias Firefly.Analytics
  alias FireflyWeb.Plugs

  def click(conn, %{"post_id" => post_id, "url" => url}) when is_binary(url) do
    with {id, ""} <- Integer.parse(to_string(post_id)),
         true <- Analytics.enabled?(),
         false <- Plugs.Analytics.do_not_track?(conn) do
      Analytics.link_click(id, url)
    end

    send_resp(conn, 204, "")
  end

  def click(conn, _params), do: send_resp(conn, 204, "")
end
