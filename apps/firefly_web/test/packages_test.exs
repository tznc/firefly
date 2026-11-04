defmodule FireflyWeb.PackagesTest do
  # Packages with plugin code need the sandbox, which runs with the web app.
  use Firefly.DataCase

  @moduletag :capture_log

  import FireflyPlugins.PluginHelpers
  import Firefly.Fixtures, only: [admin_fixture: 0]

  alias Firefly.{Packages, Plugins}
  alias Firefly.Moderation.StaffAction
  alias Firefly.Packages.{Archive, Package}
  alias Firefly.Plugins.InstalledPlugin

  setup do
    %{admin: admin_fixture()}
  end

  defp logged(action),
    do: Repo.all(from(a in StaffAction, where: a.action == ^action, select: a.details))

  defp theme_zip(manifest) do
    Archive.build(
      Map.merge(
        %{
          "id" => "look",
          "name" => "Look",
          "version" => "1.0.0",
          "firefly" => "~> 1.0",
          "tags" => ["theme"],
          "theme" => %{"css" => "theme.css"}
        },
        manifest
      ),
      %{"theme.css" => ".look {}"}
    )
  end

  defp install(zip, admin) do
    {:ok, archive} = Packages.read(zip)
    Packages.install(archive, admin)
  end

  test "a plugin package installs its plugin, disabled, and upgrades it", %{admin: admin} do
    zip = bundle_zip(%{"id" => "hello", "name" => "Hello", "tags" => ["fun"]})
    {:ok, package} = install(zip, admin)

    assert %Package{package_id: "hello", tags: ["fun"]} = package

    assert %InstalledPlugin{enabled: false, version: "1.0.0"} =
             Repo.get_by!(InstalledPlugin, plugin_id: "hello")

    assert [%{"package" => "hello", "tags" => "fun"}] = logged("package.install")
    assert [_] = logged("plugin.install")

    assert {:error, "This exact package is already installed."} = install(zip, admin)

    {:ok, _} =
      install(
        bundle_zip(%{
          "id" => "hello",
          "name" => "Hello",
          "version" => "1.1.0",
          "tags" => ["fun"]
        }),
        admin
      )

    assert Repo.get_by!(InstalledPlugin, plugin_id: "hello").version == "1.1.0"
    assert Packages.get("hello").version == "1.1.0"

    assert [%{id: "hello", kind: :plugin, plugin: %{status: :disabled}}] = Packages.list("fun")

    :ok = Packages.uninstall("hello", admin)
    assert Repo.all(InstalledPlugin) == []
    assert Packages.get("hello") == nil
  end

  test "a plugin installed before packages upgrades as one", %{admin: admin} do
    install_plugin!(admin, %{"id" => "old", "name" => "Old"})

    {:ok, archive} =
      Packages.read(bundle_zip(%{"id" => "old", "name" => "Old", "version" => "2.0.0"}))

    assert %{current: %{version: "1.0.0"}, problems: []} = Packages.preview(archive)
    {:ok, _} = Packages.install(archive, admin)
    assert Packages.get("old").version == "2.0.0"
  end

  test "themes may need plugins; plugins may only need plugins", %{admin: admin} do
    install_plugin!(admin, %{"id" => "widgets", "name" => "Widgets"})

    {:ok, _} = install(theme_zip(%{"dependencies" => %{"widgets" => "~> 1.0"}}), admin)
    assert {:error, "look need it: uninstall them first."} = Packages.uninstall("widgets", admin)

    {:error, message} =
      install(bundle_zip(%{"id" => "needs-look", "dependencies" => %{"look" => "~> 1.0"}}), admin)

    assert message =~ "It's a plugin, so it can only depend on plugins, and look is a theme."

    assert :ok = Packages.uninstall("look", admin)
    assert :ok = Packages.uninstall("widgets", admin)
  end

  test "plugin code and a theme in one package aren't supported yet", %{admin: admin} do
    zip =
      bundle_zip(
        %{
          "id" => "both",
          "main" => "index.js",
          "tags" => ["theme"],
          "theme" => %{"css" => "t.css"}
        },
        %{"index.js" => "", "t.css" => ".t {}"}
      )

    assert {:error, "A package with plugin code can't carry a theme yet" <> _} =
             install(zip, admin)

    assert Plugins.describe("both") == nil
  end

  test "core plugins can't be replaced or uninstalled", %{admin: admin} do
    with_core_plugins([FireflyPlugins.Test.GreeterPlugin], fn ->
      id = Plugins.overview() |> hd() |> Map.fetch!(:id)
      {:error, message} = install(bundle_zip(%{"id" => id, "version" => "9.0.0"}), admin)
      assert message =~ "is a core plugin"

      assert {:error, "Core plugins can't be uninstalled, only disabled."} =
               Packages.uninstall(id, admin)
    end)
  end
end
