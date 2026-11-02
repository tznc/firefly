defmodule FireflyWeb.Plugs.CurrentUser do
  @moduledoc """
  A `Plug` to assign `:current_user` based on the session.
  """

  import Plug.Conn
  alias FireflyWeb.Session

  def init(options), do: options

  def call(conn, _opts), do: assign(conn, :current_user, Session.current_user(conn))
end
