defmodule Firefly.ThemesTest do
  use Firefly.DataCase

  import Firefly.Fixtures

  alias Firefly.{SiteSettings, Themes}
  alias Firefly.Moderation.StaffAction
  alias Firefly.Themes.{Contrast, Palette}

  setup do
    on_exit(&SiteSettings.clear_cache/0)
    %{admin: admin_fixture(%{username: "boss"})}
  end

  defp theme(admin, attrs) do
    {:ok, theme} = Themes.create_theme(Map.merge(%{"name" => "Ocean"}, attrs), admin)
    theme
  end

  defp actions, do: Repo.all(from(a in StaffAction, order_by: a.id, select: a.action))

  describe "the palette" do
    test "matches the built-in themes in app.css" do
      css = File.read!(Path.expand("../../firefly_web/assets/css/app.css", __DIR__))

      for scheme <- Palette.schemes() do
        name = Palette.data_theme(scheme)
        [block] = Regex.run(~r/name: "#{name}";(.*?)\}/s, css, capture: :all_but_first)

        for token <- Palette.tokens() do
          [value] =
            Regex.run(~r/--color-#{token}: (#[0-9A-Fa-f]{6});/, block, capture: :all_but_first)

          assert String.downcase(value) == Palette.defaults()[scheme][token], "#{scheme} #{token}"
        end
      end
    end

    test "the built-in schemes meet AA, and poor colors are flagged" do
      assert Contrast.warnings(%{}) == []
      assert Float.round(Contrast.ratio("#000000", "#ffffff"), 1) == 21.0

      assert [
               %{
                 scheme: "light",
                 foreground: "base-content",
                 background: "base-100",
                 ratio: ratio
               }
               | _
             ] =
               Contrast.warnings(%{"light" => %{"base-content" => "#eeeeee"}})

      assert ratio < 4.5
    end
  end

  describe "editing and compiling" do
    # Found by Firefly.ThemesPropertyTest: Postgres can't store "\0" in
    # text, so saving one raised. NUL means nothing in a theme: it's stripped.
    test "a null character in the name, HTML or CSS is stripped", %{admin: admin} do
      assert {:ok, theme} =
               Themes.create_theme(
                 %{
                   "name" => <<"Nu", 0, "l">>,
                   "head_html" => <<"<p>", 0, "</p>">>,
                   "css" => <<"body{color:red}", 0>>
                 },
                 admin
               )

      assert {theme.name, theme.head_html, theme.css} == {"Nul", "<p></p>", "body{color:red}"}
      refute theme.compiled_css =~ <<0>>
    end

    # Found by Firefly.ThemesPropertyTest: taking "*/" out of the name once
    # turned "**//" into a new "*/", ending the stylesheet's first comment.
    test "the name can't end the stylesheet's header comment", %{admin: admin} do
      theme = theme(admin, %{"name" => "**//body{display:none}/*"})
      [header | _] = String.split(theme.compiled_css, "\n")
      assert header == "/* ** //body{display:none}/* v1 */"
    end

    test "compiles colors, CSS and assets into a versioned stylesheet", %{admin: admin} do
      theme =
        theme(admin, %{
          "colors" => %{"light" => %{"primary" => "#112233"}, "dark" => %{}},
          "css" => ".hero { background: theme-asset(hero); }"
        })

      assert theme.version == 1
      assert theme.compiled_css =~ "[data-theme=firefly] { --color-primary: #112233; }"
      refute theme.compiled_css =~ "firefly-dark"
      assert Themes.css_path(theme) == "/theme-assets/#{theme.id}/1/theme.css"

      {:ok, theme} = Themes.update_theme(theme, %{"css" => "a { color: red; }"}, admin)
      assert theme.version == 2
      assert {:ok, 2, css} = Themes.compiled_css(theme.id)
      assert css =~ "a { color: red; }"

      assert ["theme.create", "theme.update"] = actions()
    end

    @tag :tmp_dir
    test "assets are named in the CSS", %{admin: admin, tmp_dir: dir} do
      theme = theme(admin, %{"css" => ".hero { background: theme-asset(hero); }"})
      path = Firefly.UploadHelpers.image_file(dir, "hero.png")
      {:ok, _asset} = Themes.add_asset(theme, "hero", path, "hero.png", admin)
      {:ok, _version, css} = Themes.compiled_css(theme.id)
      assert css =~ ~r{background: url\("/uploads/[^"]+/hero\.png"\)}

      assert {:error, %Ecto.Changeset{}} =
               Themes.add_asset(theme, "Bad Name", path, "x.png", admin)
    end

    test "validates colors, CSS and sizes", %{admin: admin} do
      assert {:error, changeset} =
               Themes.create_theme(
                 %{"name" => "Bad", "colors" => %{"light" => %{"primary" => "red"}}},
                 admin
               )

      assert errors_on(changeset).colors != []

      for css <- ["a { color: red;", "</style><script>alert(1)</script>"] do
        assert {:error, changeset} = Themes.create_theme(%{"name" => "Bad", "css" => css}, admin)
        assert errors_on(changeset).css != []
      end

      big = String.duplicate("a", 100_001)
      assert {:error, changeset} = Themes.create_theme(%{"name" => "Big", "css" => big}, admin)
      assert errors_on(changeset).css == ["must be at most 100 KB"]

      theme(admin, %{"name" => "Taken"})
      assert {:error, changeset} = Themes.create_theme(%{"name" => "taken"}, admin)
      assert "is taken" in errors_on(changeset).name
    end

    test "components come before the theme, and recompile it when they change", %{admin: admin} do
      component = theme(admin, %{"name" => "Banner", "component" => true, "css" => ".banner {}"})
      theme = theme(admin, %{"css" => ".ocean {}"})
      {:ok, theme} = Themes.set_components(theme, [component.id], admin)
      {:ok, _v, css} = Themes.compiled_css(theme.id)
      assert css =~ ~r/\.banner \{\}.*\.ocean \{\}/s

      {:ok, _} = Themes.update_theme(component, %{"css" => ".banner { color: blue; }"}, admin)
      assert {:ok, version, css} = Themes.compiled_css(theme.id)
      assert version > theme.version
      assert css =~ ".banner { color: blue; }"
      assert {:error, :component} = Themes.set_components(component, [], admin)
    end
  end

  describe "HTML" do
    test "is cleaned unless the theme may run scripts, which then get the nonce", %{admin: admin} do
      html =
        ~s{<div class="promo" onclick="steal()">Hi <a href="javascript:x()">x</a></div><script>track()</script>}

      theme = theme(admin, %{"header_html" => html})

      cleaned = Themes.html(Themes.get_theme(theme.id), :header, "n0nce")
      assert cleaned =~ ~s{<div class="promo">}
      refute cleaned =~ "onclick"
      refute cleaned =~ "javascript"
      refute cleaned =~ "<script"

      {:ok, _} = Themes.set_allow_scripts(theme, true, admin)
      raw = Themes.html(Themes.get_theme(theme.id), :header, "n0nce")
      assert raw =~ ~s{<script nonce="n0nce">track()</script>}

      assert %{details: %{"allow_scripts" => true}} =
               Repo.get_by!(StaffAction, action: "theme.allow_scripts")
    end
  end

  describe "which theme a page uses" do
    test "a preview (admins only), then the member's pick, then the default", %{admin: admin} do
      default = theme(admin, %{"name" => "Default"})
      pickable = theme(admin, %{"name" => "Pickable", "user_selectable" => true})
      hidden = theme(admin, %{"name" => "Hidden"})
      member = user_fixture()

      assert Themes.active(member) == nil
      {:ok, _} = Themes.make_default(default, admin)
      assert Themes.active(nil).id == default.id

      assert {:error, :not_selectable} = Themes.select_for_user(member, hidden.id)
      {:ok, member} = Themes.select_for_user(member, pickable.id)
      assert Themes.active(member).id == pickable.id

      # Members can't preview; admins can.
      assert Themes.active(member, hidden.id).id == pickable.id
      assert Themes.active(admin, hidden.id).id == hidden.id

      {:ok, _} = Themes.update_theme(pickable, %{"user_selectable" => false}, admin)
      assert Themes.active(member).id == default.id

      {:ok, _} = Themes.delete_theme(default, admin)
      assert SiteSettings.get("default_theme_id") == 0
    end
  end
end
