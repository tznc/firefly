defmodule FirestormWeb.LocalTime do
  @moduledoc """
  Times people pick in their own time zone (bookmark reminders, poll
  closing times). Users have no stored time zone: app.js sends the
  browser's offset from UTC as the `tz_offset` LiveView connect param, in
  minutes as `getTimezoneOffset()` gives it (positive west of UTC), and
  `datetime-local` inputs are read and filled in that offset.
  """

  @doc "The browser's offset (see the module doc); 0 (UTC) until connected."
  def offset(socket) do
    case Phoenix.LiveView.connected?(socket) &&
           Phoenix.LiveView.get_connect_params(socket)["tz_offset"] do
      offset when is_integer(offset) and abs(offset) <= 14 * 60 -> offset
      _unknown -> 0
    end
  end

  @doc """
  A `datetime-local` value (local, `offset` minutes behind UTC) as a UTC
  `DateTime`: `{:ok, at}`, `:blank`, or `:error` if it doesn't parse.
  """
  def parse(input, offset) when is_binary(input) do
    # datetime-local values have no seconds; with them they parse too.
    input = String.trim(input)
    input = if byte_size(input) == 16, do: input <> ":00", else: input

    case NaiveDateTime.from_iso8601(input) do
      {:ok, local} -> {:ok, from_local(local, offset)}
      {:error, _} when input == "" -> :blank
      {:error, _} -> :error
    end
  end

  def parse(nil, _offset), do: :blank

  @doc "A local `NaiveDateTime` as UTC."
  def from_local(%NaiveDateTime{} = local, offset) do
    local
    |> NaiveDateTime.add(offset, :minute)
    |> NaiveDateTime.truncate(:second)
    |> DateTime.from_naive!("Etc/UTC")
  end

  @doc "The local date at `at` (UTC)."
  def to_date(%DateTime{} = at, offset),
    do: at |> DateTime.add(-offset, :minute) |> DateTime.to_date()

  @doc "`at` (UTC) as a local `datetime-local` value."
  def to_input(nil, _offset), do: nil

  def to_input(%DateTime{} = at, offset) do
    at
    |> DateTime.add(-offset, :minute)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
    |> binary_part(0, 16)
  end
end
