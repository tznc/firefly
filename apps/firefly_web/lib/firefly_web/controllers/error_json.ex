defmodule FireflyWeb.ErrorJSON do
  @moduledoc """
  Rendered for JSON requests that error, e.g. `%{errors: %{detail: "Not Found"}}`,
  or what went wrong when the database refused text (see
  `FireflyWeb.UnstorableText`).
  """
  alias FireflyWeb.UnstorableText

  def render(template, assigns) do
    detail =
      if UnstorableText.error?(assigns[:reason]),
        do: UnstorableText.message(),
        else: Phoenix.Controller.status_message_from_template(template)

    %{errors: %{detail: detail}}
  end
end
