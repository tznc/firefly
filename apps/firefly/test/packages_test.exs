defmodule Firefly.PackagesTest do
  use Firefly.DataCase

  import Firefly.Fixtures

  alias Firefly.{Packages, SiteSettings, Themes}
  alias Firefly.Moderation.StaffAction
  alias Firefly.Packages.{Archive, Package}
  alias Firefly.Themes.Theme

  setup do
    on_exit(&SiteSettings.clear_cache/0)
    %{admin: admin_fixture(%{username: "boss"})}
  end

  defp actions, do: Repo.all(from(a in StaffAction, order_by: a.id, select: a.action))

  # A theme package: `manifest` merged into a minimal valid one, `files`
  # (path => contents) with theme.css by default.
  defp theme_zip(manifest \\ %{}, files \\ %{"theme.css" => ".ocean { color: blue; }"}) do
    manifest =
      Map.merge(
        %{
          "id" => "ocean",
          "name" => "Ocean",
          "version" => "1.0.0",
          "firefly" => "~> 1.0",
          "tags" => ["theme"],
          "theme" => %{
            "colors" => %{"light" => %{"primary" => "#0b6bcb"}},
            "css" => "theme.css"
          }
        },
        manifest
      )

    Archive.build(manifest, files)
  end

  defp install!(zip, admin, opts \\ []) do
    {:ok, archive} = Packages.read(zip)
    {:ok, package} = Packages.install(archive, admin, opts)
    package
  end

  defp read_error(zip) do
    assert {:error, message} = Packages.read(zip)
    message
  end

  describe "the manifest" do
    test "a theme carries the theme tag, and the tag means a theme" do
      assert read_error(theme_zip(%{"tags" => []})) =~ "carries the theme tag"

      no_theme =
        Archive.build(
          %{
            "id" => "x1",
            "name" => "X",
            "version" => "1.0.0",
            "firefly" => "~> 1.0",
            "tags" => ["theme"]
          },
          %{"index.js" => ""}
        )

      assert read_error(no_theme) =~ "carries the theme tag"
      assert read_error(theme_zip(%{"tags" => ["Theme!"]})) =~ "\"tags\""
    end

    test "a theme needs no plugin code, and can't use plugin keys without it" do
      {:ok, archive} = Packages.read(theme_zip())
      assert archive.manifest.main == nil
      assert read_error(theme_zip(%{"hooks" => ["enabled"]})) =~ "\"hooks\" needs plugin code"
    end

    test "the theme section is checked against the files" do
      assert read_error(theme_zip(%{}, %{})) =~ "names theme.css, which isn't in the package"

      bad_color = %{"theme" => %{"colors" => %{"light" => %{"primary" => "blue"}}}}
      assert read_error(theme_zip(bad_color)) =~ "light primary must be a known token"

      bad_asset = %{"theme" => %{"assets" => %{"hero" => "missing.png"}}}
      assert read_error(theme_zip(bad_asset)) =~ "asset hero isn't in the package"

      nested = %{"theme" => %{"component" => true, "components" => [%{"name" => "A"}]}}
      assert read_error(theme_zip(nested)) =~ "a component can't include components"
      assert read_error(theme_zip(%{"theme" => %{"script" => "x"}})) =~ "unknown key \"script\""
    end

    test "limits and malformed packages" do
      assert read_error("not a zip") == "The file isn't a valid .zip."
      assert read_error(:binary.copy("x", Archive.max_size() + 1)) =~ "The package is over"
      assert read_error(Archive.build(%{}, %{})) =~ "Invalid manifest"
    end
  end

  describe "theme packages" do
    @tag :tmp_dir
    test "install creates the theme and its components, linked and logged", %{
      admin: admin,
      tmp_dir: dir
    } do
      png = File.read!(Firefly.UploadHelpers.image_file(dir, "hero.png"))

      zip =
        theme_zip(
          %{
            "theme" => %{
              "description" => "Calm.",
              "css" => "theme.css",
              "header_html" => "header.html",
              "assets" => %{"hero" => "images/hero.png"},
              "components" => [%{"name" => "Waves", "css" => "waves.css"}]
            }
          },
          %{
            "theme.css" => ".x { background: theme-asset(hero); }",
            "header.html" => ~s{<p>Hi</p><script>alert(1)</script>},
            "waves.css" => ".waves {}",
            "images/hero.png" => png
          }
        )

      package = install!(zip, admin)
      assert %Package{package_id: "ocean", version: "1.0.0", tags: ["theme"]} = package

      [theme] =
        Repo.all(from(t in Theme, where: not t.component)) |> Repo.preload([:components, :assets])

      assert theme.package_id == package.id
      assert theme.name == "Ocean"
      assert theme.description == "Calm."
      refute theme.allow_scripts
      assert [%{name: "Waves", component: true}] = theme.components
      assert [%{name: "hero"}] = theme.assets
      assert theme.compiled_css =~ "/hero.png"
      assert theme.compiled_css =~ ".waves {}"
      refute Themes.html(theme, :header, "nonce") =~ "script"
      refute Themes.locally_edited?(theme)
      assert {:error, :package} = Themes.set_allow_scripts(theme, true, admin)

      assert "package.install" in actions()
      assert "theme.create" in actions()
    end

    test "an upgrade updates the themes, and asks before replacing local edits", %{admin: admin} do
      install!(theme_zip(), admin)
      theme = Repo.get_by!(Theme, name: "Ocean")

      {:ok, archive} =
        Packages.read(theme_zip(%{"version" => "1.0.0"}, %{"theme.css" => ".same {}"}))

      assert %{problems: ["Version 1.0.0 is installed" <> _]} = Packages.preview(archive)

      {:ok, _} = Themes.update_theme(theme, %{"css" => ".mine {}"}, admin)
      assert Themes.locally_edited?(Repo.reload!(theme))

      {:ok, archive} =
        Packages.read(theme_zip(%{"version" => "1.1.0"}, %{"theme.css" => ".v2 {}"}))

      assert %{edited: ["Ocean"], problems: []} = Packages.preview(archive)
      assert {:error, message} = Packages.install(archive, admin)
      assert message =~ "Ocean changed here since version 1.0.0"
      assert Repo.reload!(theme).css == ".mine {}"

      {:ok, package} = Packages.install(archive, admin, overwrite: true)
      assert package.version == "1.1.0"
      theme = Repo.reload!(theme)
      assert theme.css == ".v2 {}"
      refute Themes.locally_edited?(theme)
      assert "package.upgrade" in actions()
    end

    test "uninstall deletes its themes; one others depend on is refused", %{admin: admin} do
      install!(theme_zip(), admin)

      install!(
        theme_zip(%{
          "id" => "ocean-dark",
          "name" => "Ocean dark",
          "dependencies" => %{"ocean" => "~> 1.0"}
        }),
        admin
      )

      assert {:error, "ocean-dark need it: uninstall them first."} =
               Packages.uninstall("ocean", admin)

      assert :ok = Packages.uninstall("ocean-dark", admin)
      assert :ok = Packages.uninstall("ocean", admin)
      assert Repo.all(Theme) == []
      assert Repo.all(Package) == []
      assert "package.uninstall" in actions()
    end

    test "a missing or incompatible dependency is refused", %{admin: admin} do
      {:ok, archive} = Packages.read(theme_zip(%{"dependencies" => %{"waves" => "~> 2.0"}}))
      assert {:error, message} = Packages.install(archive, admin)
      assert message =~ "needs plugin waves ~> 2.0, which isn't installed"
      assert Repo.all(Package) == []
    end

    test "the list and its tags", %{admin: admin} do
      install!(theme_zip(%{"tags" => ["theme", "dark"]}), admin)

      assert [%{id: "ocean", kind: :theme, themes: [%Theme{name: "Ocean"}]}] =
               Packages.list("theme")

      assert Packages.list("nope") == []
      assert "dark" in Packages.tags()
    end
  end

  describe "old theme bundles and exports" do
    @tag :tmp_dir
    test "an admin's theme exports as a package that installs elsewhere", %{
      admin: admin,
      tmp_dir: dir
    } do
      {:ok, component} = Themes.create_theme(%{"name" => "Banner", "component" => true}, admin)

      {:ok, theme} =
        Themes.create_theme(
          %{
            "name" => "Mine",
            "colors" => %{"dark" => %{"primary" => "#abcdef"}},
            "css" => ".x { background: theme-asset(logo); }"
          },
          admin
        )

      {:ok, _} = Themes.set_components(theme, [component.id], admin)
      path = Firefly.UploadHelpers.image_file(dir, "logo.png")
      {:ok, _} = Themes.add_asset(theme, "logo", path, "logo.png", admin)
      {:ok, theme} = Themes.set_allow_scripts(Themes.get_theme!(theme.id), true, admin)

      {"mine.zip", zip} = Packages.export_theme(theme)
      {:ok, archive} = Packages.read(zip)
      assert archive.manifest.tags == ["theme"]
      refute archive.files["firefly.json"] =~ "allow_scripts"

      # Installed here it's a copy, under another name.
      {:ok, package} = Packages.install(archive, admin)
      [copy] = Themes.package_themes(package.id) |> Enum.reject(& &1.component)
      copy = Themes.get_theme!(copy.id)
      assert copy.name == "Mine 2"
      refute copy.allow_scripts
      assert copy.colors == %{"dark" => %{"primary" => "#abcdef"}}
      assert [%{name: "Banner 2"}] = copy.components
      assert [%{name: "logo"}] = copy.assets
    end

    test "an old JSON bundle installs as a theme package", %{admin: admin} do
      json =
        Jason.encode!(%{
          "name" => "Retro Look",
          "description" => "Old.",
          "colors" => %{"light" => %{"primary" => "#112233"}},
          "css" => ".retro {}",
          "footer_html" => "<p>Bye</p>",
          "components" => [%{"name" => "Stripe", "css" => ".stripe {}"}],
          "assets" => []
        })

      package = install!(json, admin)
      assert %Package{package_id: "retro-look", version: "1.0.0", tags: ["theme"]} = package
      theme = Repo.get_by!(Theme, name: "Retro Look") |> Repo.preload(:components)
      assert theme.css == ".retro {}"
      assert theme.footer_html == "<p>Bye</p>"
      assert [%{name: "Stripe", css: ".stripe {}"}] = theme.components

      assert {:error, message} = Packages.read(~s({"no": "name"}))
      assert message =~ "isn't a package"
    end

    test "fetching: GitHub repositories and private addresses" do
      assert {:error, message} = Packages.fetch("ftp://example.com/x.zip")
      assert message =~ "http"
      assert {:error, message} = Packages.fetch("https://github.com/only-owner")
      assert message =~ "repository"
      assert {:error, message} = Packages.fetch("http://127.0.0.1:1/package.zip")
      assert message =~ "couldn't be fetched"
    end
  end
end
