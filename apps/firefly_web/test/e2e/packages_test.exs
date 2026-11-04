defmodule FireflyWeb.E2E.PackagesTest do
  use FireflyWeb.E2ECase, async: false

  alias Firefly.{Packages, Themes}

  @tag :tmp_dir
  test "an admin installs a theme package and the site wears it", %{conn: conn, tmp_dir: dir} do
    admin = admin_fixture("alice")

    zip =
      Packages.Archive.build(
        %{
          "id" => "ocean",
          "name" => "Ocean",
          "version" => "1.0.0",
          "firefly" => "~> 1.0",
          "tags" => ["theme"],
          "theme" => %{
            "colors" => %{"light" => %{"primary" => "#0b5394"}},
            "css" => "theme.css",
            "header_html" => "header.html"
          }
        },
        %{
          "theme.css" => "#ocean-banner { color: rgb(11, 83, 148); }",
          "header.html" => ~s{<p id="ocean-banner">Ocean waves</p>}
        }
      )

    path = Path.join(dir, "ocean.zip")
    File.write!(path, zip)

    session =
      conn
      |> log_in("alice")
      |> visit("/staff/packages")
      |> assert_has("[data-phx-main].phx-connected")
      |> upload("Package file", path)
      |> click_button("Upload")
      |> assert_has("#package-preview", text: "Install Ocean 1.0.0")
      |> click_button("#install-package", "Install")
      |> assert_has("#package-ocean", text: "Ocean")

    [theme] = Themes.list_themes()
    {:ok, _} = Themes.make_default(theme, admin)

    session
    |> visit("/")
    |> assert_has("#ocean-banner", text: "Ocean waves")
    |> evaluate(
      "getComputedStyle(document.getElementById('ocean-banner')).color",
      &assert(&1 == "rgb(11, 83, 148)")
    )
  end
end
