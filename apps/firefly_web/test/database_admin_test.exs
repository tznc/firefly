defmodule FireflyWeb.DatabaseAdminTest do
  use FireflyWeb.ConnCase

  import Ecto.Query, only: [from: 2]

  alias Firefly.{Groups, Repo, SiteSettings}
  alias Firefly.Moderation.StaffAction

  setup do
    on_exit(&SiteSettings.clear_cache/0)
    %{admin: admin_fixture(%{username: "boss"})}
  end

  defp enable(admin) do
    {:ok, _} = SiteSettings.update(%{"enable_database_admin" => "true"}, admin)
  end

  test "is a 404 while the setting is off, for admins too", %{conn: conn, admin: admin} do
    conn = log_in_as(conn, admin)

    for path <- ["/staff/db", "/staff/db/content/category", "/staff/db/people/user/#{admin.id}"] do
      assert conn |> get(path) |> response(404)
    end

    conn
    |> visit(~p"/staff")
    |> refute_has("#staff-nav a", text: "Database")
  end

  test "moderators and members are refused", %{conn: conn, admin: admin} do
    enable(admin)
    moderator = user_fixture(%{username: "mod"})
    {:ok, _} = Groups.add_role(moderator, Groups.staff_group("moderator"))

    for user <- [moderator, user_fixture()] do
      conn = log_in_as(conn, user)
      conn = get(conn, "/staff/db/content/category")
      assert redirected_to(conn) == "/"

      conn =
        put(log_in_as(build_conn(), user), "/staff/db/people/user/#{user.id}", %{
          "user" => %{"username" => "promoted"}
        })

      assert redirected_to(conn) == "/"
    end

    assert Repo.get!(Firefly.Accounts.User, moderator.id).username == "mod"

    conn
    |> log_in_as(moderator)
    |> visit(~p"/staff")
    |> refute_has("#staff-nav a", text: "Database")
  end

  test "admins list and edit records, and every edit is staff-logged", %{
    conn: conn,
    admin: admin
  } do
    enable(admin)
    category = category_fixture("Elixir")
    conn = log_in_as(conn, admin)

    conn
    |> visit(~p"/staff")
    |> assert_has("#staff-nav li.menu-title", text: "Advanced")
    |> assert_has(~s(#staff-nav a[href="/staff/db"]), text: "Database")

    assert get(conn, "/staff/db") |> redirected_to() == "/staff/db/content/category"

    html = conn |> get("/staff/db/content/category") |> html_response(200)
    assert html =~ "Elixir"
    assert html =~ ~s(id="database-admin-banner")
    assert html =~ ~s(<a href="/staff">/staff</a>)
    assert html =~ ~s(href="/assets/css/admin.css")
    refute html =~ "--color-primary"

    # Styled with the site theme's colors (only those: its CSS is for the forum).
    {:ok, theme} =
      Firefly.Themes.create_theme(
        %{
          "name" => "Ocean",
          "colors" => %{"light" => %{"primary" => "#0055aa"}},
          "css" => "p { x: y }"
        },
        admin
      )

    {:ok, _} = Firefly.Themes.make_default(theme, admin)
    html = conn |> get("/staff/db/content/category") |> html_response(200)
    assert html =~ "[data-theme=firefly] { --color-primary: #0055aa; }"
    refute html =~ "p { x: y }"

    conn =
      put(conn, "/staff/db/content/category/#{category.id}", %{
        "category" => %{"title" => "Erlang", "slug" => "hijacked"}
      })

    assert redirected_to(conn) == "/staff/db/content/category"
    category = Repo.reload!(category)
    assert category.title == "Erlang"
    refute to_string(category.slug) == "hijacked"

    assert [%{actor_id: actor_id, target_type: "category", details: details}] =
             Repo.all(from(a in StaffAction, where: a.action == "admin.update"))

    assert actor_id == admin.id
    assert details["title"] == %{"before" => "Elixir", "after" => "Erlang"}
  end

  test "secrets are never shown", %{conn: conn, admin: admin} do
    enable(admin)
    {:ok, _} = SiteSettings.update(%{"akismet_api_key" => "sekrit-akismet-key"}, admin)
    conn = log_in_as(conn, admin)

    html = conn |> get("/staff/db/people/user") |> html_response(200)
    assert html =~ "boss"
    refute html =~ "Password hash"
    refute html =~ "$2b$"

    html = conn |> get("/staff/db/people/user/#{admin.id}") |> html_response(200)
    refute html =~ "password_hash"

    html = conn |> get("/staff/db/configuration/site_setting") |> html_response(200)
    assert html =~ "enable_database_admin"
    refute html =~ "akismet_api_key"
    refute html =~ "sekrit-akismet-key"

    setting = Repo.get_by!(Firefly.SiteSettings.SiteSetting, key: "akismet_api_key")
    shown = get(conn, "/staff/db/configuration/site_setting/#{setting.id}")
    assert redirected_to(shown) == "/staff/db/configuration/site_setting"

    package =
      Repo.insert!(%Firefly.Packages.Package{
        package_id: "demo",
        name: "Demo",
        version: "1.0.0",
        manifest: %{"id" => "demo"},
        archive: "archive-bytes-xyz",
        checksum: "abc",
        settings: %{"token" => "package-token-xyz"}
      })

    plugin =
      Repo.insert!(%Firefly.Plugins.InstalledPlugin{
        plugin_id: "demo",
        source: "upload",
        version: "1.0.0",
        manifest: %{"id" => "demo"},
        package_id: package.id,
        code: "plugin-code-xyz",
        secret: "plugin-secret-xyz",
        settings: %{"token" => "settings-token-xyz"}
      })

    for path <- [
          "/staff/db/configuration/plugin",
          "/staff/db/configuration/plugin/#{plugin.id}",
          "/staff/db/configuration/package",
          "/staff/db/configuration/package/#{package.id}"
        ] do
      html = conn |> get(path) |> html_response(200)
      assert html =~ "demo"
      refute html =~ "-xyz"
    end
  end
end
