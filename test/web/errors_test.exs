defmodule FirestormWeb.Web.ErrorsTest do
  use ExUnit.Case, async: true

  alias FirestormWeb.Web.{ErrorHTML, ErrorJSON}

  test "renders HTML errors as their status message" do
    assert ErrorHTML.render("404.html", %{}) == "Not Found"
    assert ErrorHTML.render("500.html", %{}) == "Internal Server Error"
  end

  test "renders JSON errors as their status message" do
    assert ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
    assert ErrorJSON.render("500.json", %{}) == %{errors: %{detail: "Internal Server Error"}}
  end
end
