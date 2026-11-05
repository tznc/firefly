defmodule FireflyWeb.UnstorableText do
  @moduledoc """
  The web side of the database's backstop against text it can't store (a
  NUL character; see `Firefly.Text`): what a member is told when one got
  past the stripping and PostgreSQL refused it, instead of a crash page.

  A request that hits it is answered with that message by
  `FireflyWeb.ErrorHTML` and `FireflyWeb.ErrorJSON`, as a 400 (phoenix_ecto
  gives `Postgrex.Error` that status for SQLSTATE 22021); a LiveView event
  flashes it (see `FireflyWeb.LiveStripNul`).
  """

  use Gettext, backend: FireflyWeb.Gettext

  @doc "Whether `reason` (an exception) is the database refusing text."
  def error?(reason), do: is_exception(reason) and Firefly.Text.unstorable?(reason)

  @doc "What the member is told."
  def message,
    do:
      gettext(
        "Some of that text contains characters that can't be saved. Remove them and try again."
      )
end
