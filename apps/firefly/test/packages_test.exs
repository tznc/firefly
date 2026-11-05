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

  # A theme package with a file of `size` zero bytes whose headers say
  # every file is 10 bytes.
  defp lying_zip(size) do
    zip = theme_zip(%{}, %{"theme.css" => "a{}", "big.bin" => :binary.copy(<<0>>, size)})

    for {signature, offset} <- [
          {<<0x50, 0x4B, 0x03, 0x04>>, 22},
          {<<0x50, 0x4B, 0x01, 0x02>>, 24}
        ],
        {at, _} <- :binary.matches(zip, signature),
        reduce: zip do
      zip ->
        <<before::binary-size(^at + ^offset), _size::little-32, rest::binary>> = zip
        <<before::binary, 10::little-32, rest::binary>>
    end
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

  describe "limits" do
    # Found by Firefly.PackagesPropertyTest: the unpacked size was checked
    # against the sizes the zip declares, then after :zip.extract/2 had
    # inflated everything, so a zip claiming tiny files could inflate to
    # gigabytes first.
    test "a zip that lies about its sizes stops inflating at the limit" do
      zip = lying_zip(150 * 1024 * 1024)
      {:ok, entries} = :zip.list_dir(zip)
      assert Enum.all?(for({:zip_file, _, info, _, _, _} <- entries, do: elem(info, 1) == 10))

      task =
        Task.async(fn ->
          # Killed if it holds more than 100 MB, binaries included.
          Process.flag(:max_heap_size, %{
            size: div(100 * 1024 * 1024, :erlang.system_info(:wordsize)),
            kill: true,
            error_logger: false,
            include_shared_binaries: true
          })

          Packages.read(zip)
        end)

      assert Task.await(task, 30_000) == {:error, "The package unpacks to more than 20 MB."}
    end

    test "honest packages near the limit still read" do
      files = for n <- 1..4, into: %{}, do: {"f#{n}.bin", :binary.copy(<<n>>, 4 * 1024 * 1024)}
      assert {:ok, archive} = Packages.read(theme_zip(%{}, Map.put(files, "theme.css", "a{}")))
      assert archive.files["f4.bin"] == :binary.copy(<<4>>, 4 * 1024 * 1024)
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

  describe "theme settings" do
    @settings [
      %{
        "key" => "radius",
        "type" => "integer",
        "default" => 4,
        "min" => 0,
        "max" => 40,
        "label" => "Radius",
        "help" => ""
      },
      %{
        "key" => "accent",
        "type" => "string",
        "default" => "#0b6bcb",
        "label" => "Accent",
        "help" => ""
      },
      %{
        "key" => "font",
        "type" => "string",
        "default" => "Inter, sans-serif",
        "label" => "Font",
        "help" => ""
      },
      %{
        "key" => "shadow",
        "type" => "boolean",
        "default" => false,
        "label" => "Shadow",
        "help" => ""
      }
    ]

    # Found by Firefly.PackagesPropertyTest: Postgres can't store "\0" in
    # JSON, so saving one raised. It's stripped.
    test "drop a null character", %{admin: admin} do
      package = install!(theme_zip(%{"settings" => @settings}), admin)

      assert {:ok, package} =
               Packages.update_settings(
                 package,
                 %{"radius" => "4", "accent" => "#0b6bcb", "font" => <<"a", 0>>},
                 admin
               )

      assert package.settings["font"] == "a"
    end

    # Found by Firefly.PackagesPropertyTest: an unbalanced bracket left the
    # value bare (taking in the rest of the stylesheet), and \f, which ends
    # a CSS string as a newline does, wasn't escaped.
    test "can't break out of their declaration", %{admin: admin} do
      package = install!(theme_zip(%{"settings" => @settings}), admin)

      for {font, css} <- [
            {"(", ~s|--ocean-font: "(";|},
            {"a) b", ~s|--ocean-font: "a) b";|},
            {"x\f;} body{display:none} :root{",
             ~s|--ocean-font: "x\\0C ;} body{display:none} :root{";|},
            {"(\u0301", ~s|--ocean-font: "(\u0301";|},
            {"Inter (sans)", "--ocean-font: Inter (sans);"}
          ] do
        params = %{"radius" => "4", "accent" => "#0b6bcb", "font" => font}
        {:ok, _} = Packages.update_settings(package, params, admin)
        assert Packages.css_variables(package.id) =~ css
      end
    end

    test "reach the CSS as custom properties, and a change compiles it again", %{admin: admin} do
      package = install!(theme_zip(%{"settings" => @settings}), admin)
      theme = Repo.get_by!(Theme, name: "Ocean")

      assert theme.compiled_css =~
               ":root { --ocean-radius: 4; --ocean-accent: #0b6bcb; --ocean-font: Inter, sans-serif; --ocean-shadow: 0; }"

      assert {:error, %{"radius" => "must be at most 40"}} =
               Packages.update_settings(package, %{"radius" => "99"}, admin)

      {:ok, package} =
        Packages.update_settings(
          package,
          %{
            "radius" => "12",
            "accent" => "#ff0000",
            "font" => "x; } body { display: none",
            "shadow" => "true"
          },
          admin
        )

      assert package.settings["radius"] == 12
      theme = Repo.reload!(theme)
      assert theme.version > 1
      assert theme.compiled_css =~ "--ocean-radius: 12;"
      assert theme.compiled_css =~ "--ocean-shadow: 1;"
      # Text that could end the declaration is a CSS string.
      assert theme.compiled_css =~ ~s|--ocean-font: "x; } body { display: none";|
      refute Themes.locally_edited?(theme)
      assert "package.settings" in actions()
    end

    test "a plugin's package keeps its settings with the plugin", %{admin: admin} do
      package = install!(theme_zip(), admin)
      assert Packages.settings(package) == {[], %{}}
      assert Packages.css_variables(package.id) == ""
    end
  end
end
