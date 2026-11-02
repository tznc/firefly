defmodule FireflyWeb.LocalTime do
  @moduledoc """
  The browser's time zone for times people pick in their own (see
  `Firefly.LocalTime`): app.js sends the browser's offset from UTC as the
  `tz_offset` LiveView connect param, in minutes as `getTimezoneOffset()`
  gives it (positive west of UTC).
  """

  @doc "The browser's offset; 0 (UTC) until connected."
  def offset(socket) do
    case Phoenix.LiveView.connected?(socket) &&
           Phoenix.LiveView.get_connect_params(socket)["tz_offset"] do
      offset when is_integer(offset) and abs(offset) <= 14 * 60 -> offset
      _unknown -> 0
    end
  end

  @doc "`at` (UTC) as a local `datetime-local` value."
  defdelegate to_input(at, offset), to: Firefly.LocalTime
end
