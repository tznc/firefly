defmodule FireflyWeb.PackagesLiveTest do
  use FireflyWeb.ConnCase

  import FireflyPlugins.PluginHelpers

  alias Firefly.Plugins
  alias Firefly.Plugins.Health

  setup %{conn: conn} do
    admin = admin_fixture(%{username: "boss"})
    %{admin: admin, conn: log_in_as(conn, admin)}
  end

  defp write_zip(zip) do
    path = Path.join(System.tmp_dir!(), "plugin-#{System.unique_integer([:positive])}.zip")
    File.write!(path, zip)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "members can't manage packages", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/packages")
    |> assert_path(~p"/")
  end

  test "uploading shows the permissions, then installs and enables", %{conn: conn, admin: admin} do
    install_plugin!(admin, %{"id" => "base", "name" => "Base"})

    zip =
      bundle_zip(%{
        "id" => "hello",
        "name" => "Hello",
        "description" => "Says hello.",
        "permissions" => ["read"],
        "dependencies" => %{"base" => "~> 1.0"}
      })

    session =
      conn
      |> visit(~p"/staff/packages")
      |> upload("Package file", write_zip(zip))
      |> click_button("Upload")
      |> assert_has("#package-preview h2", text: "Install Hello 1.0.0")
      |> assert_has("#preview-permissions",
        text: "Can read public posts, threads and member profiles"
      )
      |> click_button("#install-package", "Install")
      |> assert_has("#package-hello", text: "disabled")
      |> assert_has("#package-hello", text: "base ~> 1.0: inactive")
      |> assert_has("#package-base", text: "Needed by hello")

    session
    |> within("#package-hello", &click_button(&1, "Enable"))
    |> assert_has("#confirm-cascade", text: "base")
    |> click_button("#confirm-package-action", "Enable")
    |> assert_has("#package-hello", text: "enabled")
    |> assert_has("#package-base", text: "enabled")

    assert Enum.map(Plugins.active(), & &1.id) == ["base", "hello"]
  end

  test "an upload with problems can't be installed", %{conn: conn} do
    zip = bundle_zip(%{"id" => "needy", "dependencies" => %{"gone" => "~> 1.0"}})

    conn
    |> visit(~p"/staff/packages")
    |> upload("Package file", write_zip(zip))
    |> click_button("Upload")
    |> assert_has("#preview-problems",
      text: "It needs plugin gone ~> 1.0, which isn't installed."
    )
    |> assert_has("#install-package[disabled]")
  end

  test "network access is named in plain words, and an upgrade highlights what's new", %{
    conn: conn,
    admin: admin
  } do
    install_plugin!(admin, %{
      "id" => "hook",
      "name" => "Hook",
      "permissions" => ["http"],
      "http_hosts" => ["api.example.com"]
    })

    conn
    |> visit(~p"/staff/plugins/hook")
    |> assert_has("#plugin-permissions", text: "Can send forum content to: api.example.com")

    zip =
      bundle_zip(%{
        "id" => "hook",
        "name" => "Hook",
        "version" => "1.1.0",
        "permissions" => ["http", "notify"],
        "http_hosts" => ["api.example.com", "hooks.slack.com"]
      })

    conn
    |> visit(~p"/staff/packages")
    |> upload("Package file", write_zip(zip))
    |> click_button("Upload")
    |> assert_has("#package-preview h2", text: "Upgrade Hook 1.1.0")
    |> assert_has("#preview-more-access", text: "asks for more than version 1.0.0")
    |> assert_has("#preview-permissions-http",
      text: "Can send forum content to: api.example.com, hooks.slack.com"
    )
    |> assert_has("#preview-permissions-http .badge-warning", text: "new: hooks.slack.com")
    |> refute_has("#preview-permissions-http .badge-warning", text: "api.example.com")
    |> assert_has("#preview-permissions-notify .badge", text: "new")
    |> assert_has("#preview-permissions-notify", text: "Can send members notifications")
  end

  test "an upgrade asking for nothing more isn't flagged", %{conn: conn, admin: admin} do
    install_plugin!(admin, %{"id" => "same", "name" => "Same", "permissions" => ["read"]})

    zip =
      bundle_zip(%{
        "id" => "same",
        "name" => "Same",
        "version" => "1.0.1",
        "permissions" => ["read"]
      })

    conn
    |> visit(~p"/staff/packages")
    |> upload("Package file", write_zip(zip))
    |> click_button("Upload")
    |> assert_has("#package-preview h2", text: "Upgrade Same 1.0.1")
    |> refute_has("#preview-more-access")
    |> refute_has("#preview-permissions .badge")
  end

  test "a malformed bundle says what's wrong", %{conn: conn} do
    conn
    |> visit(~p"/staff/packages")
    |> upload("Package file", write_zip(zip(%{"index.js" => ""})))
    |> click_button("Upload")
    |> assert_has(".alert", text: "The package has no firefly.json (or plugin.json).")
  end

  test "disabling lists the plugins that need it", %{conn: conn, admin: admin} do
    install_plugin!(admin, %{"id" => "base", "name" => "Base"})

    install_plugin!(
      admin,
      %{"id" => "app", "name" => "App", "dependencies" => %{"base" => "~> 1.0"}},
      nil,
      enable: true
    )

    conn
    |> visit(~p"/staff/packages")
    |> within("#package-base", &click_button(&1, "Disable"))
    |> assert_has("#confirm-cascade", text: "app")
    |> click_button("#confirm-package-action", "Disable")
    |> assert_has("#package-app", text: "disabled")

    assert Plugins.active() == []
  end

  test "uninstalling one that others need is refused", %{conn: conn, admin: admin} do
    install_plugin!(admin, %{"id" => "base", "name" => "Base"})

    install_plugin!(admin, %{
      "id" => "app",
      "name" => "App",
      "dependencies" => %{"base" => "~> 1.0"}
    })

    conn
    |> visit(~p"/staff/packages")
    |> within("#package-base", &click_button(&1, "Uninstall"))
    |> assert_has(".alert", text: "app need it: uninstall them first.")
    |> within("#package-app", &click_button(&1, "Uninstall"))
    |> click_button("#confirm-package-action", "Uninstall")
    |> refute_has("#package-app")
  end

  test "the settings form comes from the manifest", %{conn: conn, admin: admin} do
    settings = [
      %{"key" => "greeting", "type" => "string", "default" => "Hi", "label" => "Greeting"},
      %{"key" => "times", "type" => "integer", "default" => 1, "min" => 1, "label" => "Times"},
      %{"key" => "loud", "type" => "boolean", "default" => false, "label" => "Loud"},
      %{
        "key" => "color",
        "type" => "enum",
        "choices" => ["red", "blue"],
        "default" => "red",
        "label" => "Color"
      }
    ]

    id = install_plugin!(admin, %{"settings" => settings, "permissions" => ["read"]})
    Health.log_error(id, "enabled", :js_error, "it broke")

    conn
    |> visit(~p"/staff/plugins/#{id}")
    |> assert_has("#plugin-permissions", text: "Can read public posts")
    |> assert_has("#plugin-errors", text: "it broke")
    |> fill_in("Times", with: "0")
    |> click_button("Save settings")
    |> assert_has(".alert", text: "Some settings are invalid")
    |> fill_in("Greeting", with: "Hey")
    |> fill_in("Times", with: "3")
    |> check("Loud")
    |> select("Color", option: "blue")
    |> click_button("Save settings")
    |> assert_has(".alert", text: "Settings saved.")

    assert %{settings: %{"greeting" => "Hey", "times" => 3, "loud" => true, "color" => "blue"}} =
             Plugins.describe(id)
  end

  describe "themes and plugins in one list" do
    defp theme_zip(manifest \\ %{}, css \\ ".ocean {}") do
      Firefly.Packages.Archive.build(
        Map.merge(
          %{
            "id" => "ocean",
            "name" => "Ocean",
            "version" => "1.0.0",
            "firefly" => "~> 1.0",
            "tags" => ["theme"],
            "theme" => %{"css" => "theme.css"}
          },
          manifest
        ),
        %{"theme.css" => css}
      )
    end

    test "the old plugins page leads here", %{conn: conn} do
      assert redirected_to(get(conn, "/staff/plugins")) == "/staff/packages"
    end

    test "a theme package is uploaded, previewed and installed", %{conn: conn} do
      conn
      |> visit(~p"/staff/packages")
      |> upload("Package file", write_zip(theme_zip(%{"description" => "Calm blues."})))
      |> click_button("Upload")
      |> assert_has("#package-preview h2", text: "Install Ocean 1.0.0")
      |> assert_has("#preview-themes li", text: "Ocean")
      |> refute_has("#preview-permissions")
      |> click_button("#install-package", "Install")
      |> assert_has("#flash-info", text: "Ocean 1.0.0 installed.")
      |> assert_has("#package-ocean", text: "theme")
      |> assert_has("#package-ocean a", text: "Ocean")

      assert [%{name: "Ocean", package_id: id}] = Firefly.Themes.list_themes()
      assert id
    end

    test "the tag filter shows themes or plugins", %{conn: conn, admin: admin} do
      {:ok, archive} = Firefly.Packages.read(theme_zip())
      {:ok, _} = Firefly.Packages.install(archive, admin)
      install_plugin!(admin, %{"id" => "hello", "name" => "Hello", "tags" => ["fun"]})

      conn
      |> visit(~p"/staff/packages")
      |> assert_has("#package-ocean")
      |> assert_has("#package-hello")
      |> click_link("#tag-theme", "theme")
      |> assert_path(~p"/staff/packages", query_params: %{tag: "theme"})
      |> assert_has("#package-ocean")
      |> refute_has("#package-hello")
      |> click_link("#tag-fun", "fun")
      |> assert_has("#package-hello")
      |> refute_has("#package-ocean")
    end

    test "upgrading a theme edited here asks to replace the changes", %{conn: conn, admin: admin} do
      {:ok, archive} = Firefly.Packages.read(theme_zip())
      {:ok, _} = Firefly.Packages.install(archive, admin)
      [theme] = Firefly.Themes.list_themes()
      {:ok, _} = Firefly.Themes.update_theme(theme, %{"css" => ".mine {}"}, admin)

      conn
      |> visit(~p"/staff/packages")
      |> upload("Package file", write_zip(theme_zip(%{"version" => "1.1.0"}, ".v2 {}")))
      |> click_button("Upload")
      |> assert_has("#preview-edited", text: "Ocean")
      |> assert_has("#install-package[disabled]")
      |> check("Replace the changes made here")
      |> click_button("#install-package", "Upgrade")
      |> assert_has("#flash-info", text: "Ocean 1.1.0 upgraded.")

      assert Firefly.Repo.reload!(theme).css == ".v2 {}"
    end

    test "uninstalling a theme package deletes its themes", %{conn: conn, admin: admin} do
      {:ok, archive} = Firefly.Packages.read(theme_zip())
      {:ok, _} = Firefly.Packages.install(archive, admin)

      conn
      |> visit(~p"/staff/packages")
      |> within("#package-ocean", &click_button(&1, "Uninstall"))
      |> click_button("#confirm-package-action", "Uninstall")
      |> refute_has("#package-ocean")

      assert Firefly.Themes.list_themes() == []
    end
  end

  test "a plugin's theme components need the grant", %{conn: conn} do
    zip =
      bundle_zip(
        %{
          "id" => "styled",
          "name" => "Styled",
          "main" => "index.js",
          "tags" => ["theme"],
          "theme" => %{"name" => "Styled bits", "component" => true, "css" => "s.css"}
        },
        %{"index.js" => "", "s.css" => ".s {}"}
      )

    conn
    |> visit(~p"/staff/packages")
    |> upload("Package file", write_zip(zip))
    |> click_button("Upload")
    |> assert_has("#preview-themes li", text: "Styled bits")
    |> assert_has("#preview-grant", text: "Its plugin also ships theme components")
    |> assert_has("#install-package[disabled]")
    |> check("Allow its theme components")
    |> click_button("#install-package", "Install")
    |> assert_has("#flash-info", text: "Styled 1.0.0 installed (disabled).")
    |> assert_has("#package-styled", text: "Styled bits")

    assert Firefly.Packages.get("styled").theme_granted_at
  end
end
