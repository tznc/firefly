defmodule FireflyWeb.ErrorHTML do
  @moduledoc """
  Rendered for HTML requests that error. Returns the status message, e.g.
  "Not Found" for 404.
  """
  use FireflyWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
