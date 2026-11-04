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

  defp styled_plugin(manifest \\ %{}) do
    bundle_zip(
      Map.merge(
        %{
          "id" => "styled",
          "name" => "Styled",
          "main" => "index.js",
          "tags" => ["theme"],
          "theme" => %{
            "name" => "Styled bits",
            "component" => true,
            "colors" => %{"light" => %{"accent" => "#123456"}},
            "css" => "styled.css",
            "footer_html" => "footer.html"
          }
        },
        manifest
      ),
      %{
        "index.js" => "exports.enabled = () => null;",
        "styled.css" => ".styled-widget { color: red; }",
        "footer.html" => ~s{<p onclick="steal()">Hi</p><script>steal()</script>}
      }
    )
  end

  describe "theme components from plugins" do
    test "need staff's grant, which is logged; their HTML is cleaned", %{admin: admin} do
      {:ok, archive} = Packages.read(styled_plugin())
      assert %{grant_needed: true, problems: []} = Packages.preview(archive)

      assert {:error, "Its plugin ships theme components: allow them to install it."} =
               Packages.install(archive, admin)

      assert Plugins.describe("styled") == nil

      {:ok, package} = Packages.install(archive, admin, grant_theme: true)
      assert package.theme_granted_at
      assert package.theme_granted_by_id == admin.id

      assert [%{"package" => "styled", "components" => "Styled bits"}] =
               logged("package.theme_grant")

      assert %{source: "upload"} = Plugins.describe("styled")

      [component] = Firefly.Themes.package_themes(package.id) |> Repo.preload(:components)
      assert %{component: true, allow_scripts: false, name: "Styled bits"} = component
      assert component.compiled_css =~ ".styled-widget"
      assert component.compiled_css =~ "--color-accent: #123456;"
      html = Firefly.Themes.html(component, :footer, "nonce")
      assert html =~ "Hi"
      refute html =~ "script"
      refute html =~ "onclick"
      assert {:error, :package} = Firefly.Themes.set_allow_scripts(component, true, admin)

      assert [%{themes: [_]}] = Packages.list("theme")

      # An upgrade keeps the grant.
      {:ok, archive} = Packages.read(styled_plugin(%{"version" => "1.1.0"}))
      assert %{grant_needed: false} = Packages.preview(archive)
      {:ok, _} = Packages.install(archive, admin)
      assert length(logged("package.theme_grant")) == 1

      :ok = Packages.uninstall("styled", admin)
      assert Firefly.Themes.list_components() == []
    end

    test "are components only", %{admin: admin} do
      zip = styled_plugin(%{"theme" => %{"css" => "styled.css"}})
      {:error, message} = install(zip, admin)
      assert message =~ "its theme must be a component"
      assert Plugins.describe("styled") == nil
    end
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
