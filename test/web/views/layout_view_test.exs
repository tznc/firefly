defmodule FirestormWeb.Web.LayoutViewTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.Web.LayoutView

  test "css_link_tag/0 links the Sass and the JS-imported stylesheets" do
    assert LayoutView.css_link_tag() =~ ~s(href="/css/app.css")
    assert LayoutView.css_link_tag() =~ ~s(href="/js/app.css")
  end

  test "js_script_tag/0 links the bundled JavaScript" do
    assert LayoutView.js_script_tag() == ~s(<script src="/js/app.js"></script>)
  end

  test "the app layout renders flash messages and the page content", %{conn: conn} do
    {:ok, user} =
      FirestormWeb.Forums.create_user(%{
        username: "flash",
        email: "flash@example.com",
        name: "Flash"
      })

    conn =
      conn |> log_in_as(user) |> post(category_path(conn, :create), category: %{title: "Flashy"})

    html = conn |> recycle() |> get(redirected_to(conn)) |> html_response(200)

    assert html =~ "Category created successfully."
    assert html =~ "Flashy"
    assert html =~ ~s(<link rel="stylesheet" type="text/css" href="/css/app.css" />)
  end
end
