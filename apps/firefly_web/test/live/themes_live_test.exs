defmodule FireflyWeb.ThemesLiveTest do
  use FireflyWeb.ConnCase

  import Ecto.Query, only: [from: 2]

  alias Firefly.{Repo, SiteSettings, Themes}
  alias Firefly.Moderation.StaffAction

  defmodule Bundles do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/theme.json"} = conn, _opts) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"name": "Remote", "css": ".remote {}"}))
    end

    def call(conn, _opts), do: send_resp(conn, 404, "")
  end

  setup do
    on_exit(&SiteSettings.clear_cache/0)
    %{admin: admin_fixture(%{username: "boss"})}
  end

  defp theme(admin, attrs) do
    {:ok, theme} = Themes.create_theme(Map.merge(%{"name" => "Ocean"}, attrs), admin)
    theme
  end

  defp nonce(conn) do
    [csp] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([^']+)'/, csp)
    nonce
  end

  test "members can't reach the themes admin or preview", %{conn: conn, admin: admin} do
    theme = theme(admin, %{})
    member_conn = log_in_as(conn, user_fixture())

    for path <- ["/staff/themes", "/staff/themes/#{theme.id}"] do
      member_conn |> visit(path) |> assert_path(~p"/")
    end

    assert redirected_to(post(member_conn, ~p"/staff/themes/#{theme.id}/preview")) == "/"
    assert redirected_to(get(member_conn, ~p"/staff/themes/#{theme.id}/export")) == "/"
  end

  describe "every page" do
    test "has a CSP whose nonce the inline scripts carry", %{conn: conn} do
      conn = get(conn, ~p"/")
      nonce = nonce(conn)
      assert html_response(conn, 200) =~ ~s{<script nonce="#{nonce}">}
      [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "script-src 'self' 'nonce-"
      assert nonce != nonce(get(build_conn(), ~p"/"))
    end

    test "uses the default theme's stylesheet and cleaned HTML", %{conn: conn, admin: admin} do
      theme =
        theme(admin, %{
          "css" => "body { letter-spacing: 0; }",
          "header_html" => ~s{<p id="promo" onclick="x()">Welcome</p><script>evil()</script>},
          "footer_html" => ~s{<p id="colophon">Made here</p>}
        })

      {:ok, _} = Themes.make_default(theme, admin)

      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s{href="/theme-assets/#{theme.id}/1/theme.css"}
      assert html =~ ~s{<p id="promo">Welcome</p>}
      assert html =~ ~s{<p id="colophon">Made here</p>}
      refute html =~ "evil()"
      refute html =~ "onclick"
    end

    test "a theme allowed to run scripts gets the page's nonce", %{conn: conn, admin: admin} do
      theme = theme(admin, %{"head_html" => "<script>window.analytics = 1</script>"})
      {:ok, theme} = Themes.set_allow_scripts(theme, true, admin)
      {:ok, _} = Themes.make_default(theme, admin)

      conn = get(conn, ~p"/")

      assert html_response(conn, 200) =~
               ~s{<script nonce="#{nonce(conn)}">window.analytics = 1</script>}
    end
  end

  describe "the stylesheet" do
    test "is cached for good at its version's URL", %{conn: conn, admin: admin} do
      theme = theme(admin, %{"css" => ".a { color: red; }"})

      conn = get(conn, "/theme-assets/#{theme.id}/1/theme.css")
      assert response(conn, 200) =~ ".a { color: red; }"
      assert get_resp_header(conn, "content-type") == ["text/css; charset=utf-8"]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]

      stale = get(build_conn(), "/theme-assets/#{theme.id}/0/theme.css")
      assert get_resp_header(stale, "cache-control") == ["no-cache"]
      assert response(get(build_conn(), "/theme-assets/999999/1/theme.css"), 404)
    end
  end

  describe "the admin" do
    test "creates and edits a theme, warning about poor contrast", %{conn: conn, admin: admin} do
      session =
        conn
        |> log_in_as(admin)
        |> visit(~p"/staff/themes")
        |> assert_has("#builtin-default")
        |> within("#theme-form", fn session ->
          session |> fill_in("Name", with: "Forest") |> click_button("Create")
        end)
        |> assert_has("h1", text: "Forest")
        |> assert_has("#contrast-ok")

      theme = Repo.get_by!(Themes.Theme, name: "Forest")

      session
      |> fill_in("#color-light-base-content", "base-content", with: "#fefefe", exact: false)
      |> assert_has("#contrast-warnings", text: "base-content on base-100")
      |> fill_in("Custom CSS", with: ".forest { color: green; }")
      |> click_button("Save theme")
      |> assert_has("#flash-info", text: "Theme saved.")

      theme = Themes.get_theme!(theme.id)
      assert theme.colors["light"] == %{"base-content" => "#fefefe"}
      assert theme.colors["dark"] == %{}
      assert theme.compiled_css =~ ".forest"

      session
      |> click_button("Make default")
      |> assert_has("#flash-info", text: "Forest is the site's theme now.")

      assert SiteSettings.get("default_theme_id") == theme.id
    end

    test "allowing scripts and attaching components are logged", %{conn: conn, admin: admin} do
      component = theme(admin, %{"name" => "Banner", "component" => true})
      theme = theme(admin, %{})

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/themes/#{theme.id}")
      |> click_button("Allow scripts")
      |> assert_has("#flash-info", text: "Its HTML may run scripts now.")
      |> check("Banner")
      |> click_button("Save components")
      |> assert_has("#flash-info", text: "Components saved.")

      assert [%{id: id}] = Themes.get_theme!(theme.id).components
      assert id == component.id

      assert Repo.all(from(a in StaffAction, where: a.action == "theme.allow_scripts")) != []
    end

    test "previews a theme just for the admin", %{conn: conn, admin: admin} do
      theme = theme(admin, %{"name" => "Preview me"})

      conn = conn |> log_in_as(admin) |> post(~p"/staff/themes/#{theme.id}/preview")
      assert redirected_to(conn) == "/"

      html = conn |> recycle() |> get(~p"/") |> html_response(200)
      assert html =~ "theme-preview-banner"
      assert html =~ ~s{href="/theme-assets/#{theme.id}/}

      # Others still see the built-in look.
      refute build_conn() |> get(~p"/") |> html_response(200) =~ "/theme-assets/"

      stopped = conn |> recycle() |> delete(~p"/staff/themes/preview")
      assert redirected_to(stopped) == "/staff/themes/#{theme.id}"
      refute get_session(stopped, :preview_theme_id)
    end

    @tag :tmp_dir
    test "exports a package that installs on the packages page", %{
      conn: conn,
      admin: admin,
      tmp_dir: dir
    } do
      theme = theme(admin, %{"css" => ".exported {}"})
      conn = log_in_as(conn, admin)

      export = get(conn, ~p"/staff/themes/#{theme.id}/export")

      assert get_resp_header(export, "content-disposition") == [
               ~s{attachment; filename="ocean.zip"}
             ]

      path = Path.join(dir, "ocean.zip")
      File.write!(path, export.resp_body)

      conn
      |> visit(~p"/staff/packages")
      |> upload("Package file", path)
      |> click_button("Upload")
      |> click_button("#install-package", "Install")
      |> assert_has("#flash-info", text: "Ocean 1.0.0 installed.")

      copy = Repo.get_by!(Themes.Theme, name: "Ocean 2")
      assert copy.css == ".exported {}"

      conn
      |> visit(~p"/staff/themes/#{copy.id}")
      |> assert_has("#theme-package", text: "From the package Ocean 1.0.0.")
      |> refute_has("button", text: "Allow scripts")
    end

    test "an old bundle installs from a URL", %{conn: conn, admin: admin} do
      {:ok, server} = start_supervised({Bandit, plug: Bundles, ip: {127, 0, 0, 1}, port: 0})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      http = Application.get_env(:firefly, Firefly.Plugins.HTTP, [])
      Application.put_env(:firefly, Firefly.Plugins.HTTP, allow_private: [{127, 0, 0, 1}])
      on_exit(fn -> Application.put_env(:firefly, Firefly.Plugins.HTTP, http) end)

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/themes")
      |> click_link("Theme packages")
      |> fill_in("Or from a URL or GitHub repository",
        with: "http://127.0.0.1:#{port}/theme.json"
      )
      |> click_button("Fetch")
      |> assert_has("#package-preview h2", text: "Install Remote 1.0.0")
      |> click_button("#install-package", "Install")
      |> assert_has("#flash-info", text: "Remote 1.0.0 installed.")

      assert Repo.get_by!(Themes.Theme, name: "Remote").css == ".remote {}"
      assert Firefly.Packages.get("remote").source_url =~ "/theme.json"
    end
  end

  describe "members" do
    test "pick a selectable theme in their interface settings", %{conn: conn, admin: admin} do
      theme = theme(admin, %{"name" => "Night", "user_selectable" => true})
      member = user_fixture()

      conn
      |> log_in_as(member)
      |> visit(~p"/settings/interface")
      |> select("Site theme", option: "Night")
      |> click_button("Use this theme")

      assert Firefly.Accounts.get_user!(member.id).theme_id == theme.id

      html = conn |> log_in_as(member) |> get(~p"/") |> html_response(200)
      assert html =~ "/theme-assets/#{theme.id}/"
    end
  end
end
