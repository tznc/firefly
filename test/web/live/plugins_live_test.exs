defmodule FirestormWeb.Web.PluginsLiveTest do
  use FirestormWeb.Web.ConnCase

  import FirestormWeb.PluginHelpers

  alias FirestormWeb.Plugins
  alias FirestormWeb.Plugins.Health

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

  test "members can't manage plugins", %{conn: conn} do
    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/staff/plugins")
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
      |> visit(~p"/staff/plugins")
      |> upload("Bundle", write_zip(zip))
      |> click_button("Upload")
      |> assert_has("#plugin-preview h2", text: "Install Hello 1.0.0")
      |> assert_has("#preview-permissions", text: "Read public posts, threads and user profiles")
      |> click_button("#install-plugin", "Install")
      |> assert_has("#plugin-hello", text: "disabled")
      |> assert_has("#plugin-hello", text: "base ~> 1.0: inactive")
      |> assert_has("#plugin-base", text: "Needed by hello")

    session
    |> within("#plugin-hello", &click_button(&1, "Enable"))
    |> assert_has("#confirm-cascade", text: "base")
    |> click_button("#confirm-plugin-action", "Enable")
    |> assert_has("#plugin-hello", text: "enabled")
    |> assert_has("#plugin-base", text: "enabled")

    assert Enum.map(Plugins.active(), & &1.id) == ["base", "hello"]
  end

  test "an upload with problems can't be installed", %{conn: conn} do
    zip = bundle_zip(%{"id" => "needy", "dependencies" => %{"gone" => "~> 1.0"}})

    conn
    |> visit(~p"/staff/plugins")
    |> upload("Bundle", write_zip(zip))
    |> click_button("Upload")
    |> assert_has("#preview-problems",
      text: "It needs plugin gone ~> 1.0, which isn't installed."
    )
    |> assert_has("#install-plugin[disabled]")
  end

  test "a malformed bundle says what's wrong", %{conn: conn} do
    conn
    |> visit(~p"/staff/plugins")
    |> upload("Bundle", write_zip(zip(%{"index.js" => ""})))
    |> click_button("Upload")
    |> assert_has(".alert", text: "The bundle has no plugin.json.")
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
    |> visit(~p"/staff/plugins")
    |> within("#plugin-base", &click_button(&1, "Disable"))
    |> assert_has("#confirm-cascade", text: "app")
    |> click_button("#confirm-plugin-action", "Disable")
    |> assert_has("#plugin-app", text: "disabled")

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
    |> visit(~p"/staff/plugins")
    |> within("#plugin-base", &click_button(&1, "Uninstall"))
    |> assert_has(".alert", text: "app need it: uninstall them first.")
    |> within("#plugin-app", &click_button(&1, "Uninstall"))
    |> click_button("#confirm-plugin-action", "Uninstall")
    |> refute_has("#plugin-app")
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
    |> assert_has("#plugin-permissions", text: "read")
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
end
