defmodule FireflyWeb.ErrorHTML do
  @moduledoc """
  Rendered for HTML requests that error. Returns the status message, e.g.
  "Not Found" for 404, or what went wrong when the database refused text
  (see `FireflyWeb.UnstorableText`).
  """
  use FireflyWeb, :html

  alias FireflyWeb.UnstorableText

  def render(template, assigns) do
    if UnstorableText.error?(assigns[:reason]),
      do: UnstorableText.message(),
      else: Phoenix.Controller.status_message_from_template(template)
  end
end
