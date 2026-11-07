defmodule FireflyWeb.SiteSettingsTest do
  use FireflyWeb.ConnCase
  import Swoosh.TestAssertions

  # Mail is sent from other processes (LiveViews).
  setup :set_swoosh_global

  import Ecto.Query, only: [from: 2]
  import Firefly.DataCase, only: [errors_on: 1, run_notifications: 0]

  alias Firefly.{Accounts, Discussion, Notifications, RateLimit, Repo, SiteSettings}
  alias Firefly.Discussion.Mentions
  alias Firefly.Moderation.Posting
  alias Firefly.Notifications.Emails

  alias Firefly.Discussion.{Policy, Tag}
  alias Firefly.Moderation.StaffAction

  setup do
    %{admin: admin_fixture(%{username: "boss"})}
  end

  defp set(admin, settings), do: {:ok, _} = SiteSettings.update(settings, admin)

  defp register(username) do
    Accounts.register_user(%{
      username: username,
      email: "#{username}@example.com",
      password: "tangerine-otter-galaxy"
    })
  end

  test "defaults are the site's prior behavior" do
    assert %{
             "title" => "Firefly",
             "description" => "",
             "contact_email" => "",
             "allow_registrations" => true,
             "require_email_confirmation" => true,
             "new_user_max_links" => 2,
             "approve_unless_trust_level" => 0,
             "min_trust_to_send_messages" => 1,
             "max_mentions" => 10,
             "tags_admin_only" => false,
             "max_tags_per_thread" => 5,
             "edit_grace_minutes" => 0
           } = SiteSettings.all()

    # Seeded from the deployment's config
    assert SiteSettings.get("posts_per_minute") == 1_000
    System.put_env("FIREFLY_TAGS_ADMIN_ONLY", "1")
    on_exit(fn -> System.delete_env("FIREFLY_TAGS_ADMIN_ONLY") end)
    assert SiteSettings.get("tags_admin_only")
    assert SiteSettings.env_override("tags_admin_only") == "FIREFLY_TAGS_ADMIN_ONLY"
  end

  describe "the settings page" do
    test "is for admins only", %{conn: conn} do
      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/staff/settings")
      |> assert_path(~p"/")
      |> assert_has("#flash-error", text: "You are not allowed to do that.")
    end

    test "saves valid settings, logging old and new values", %{conn: conn, admin: admin} do
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/settings")
      |> assert_has("#settings-registration legend", text: "Registration")
      |> fill_in("Title", with: "Glowworm")
      |> uncheck("Allow new registrations")
      |> fill_in("Edit window (minutes)", with: "30")
      |> click_button("Save settings")
      |> assert_has("#flash-info", text: "Settings saved")
      |> assert_has("header", text: "Glowworm")

      assert %{"title" => "Glowworm", "allow_registrations" => false, "edit_grace_minutes" => 30} =
               SiteSettings.all()

      log = Repo.all(from(a in StaffAction, where: a.action == "setting.update", order_by: a.id))

      assert Enum.map(log, & &1.details["key"]) |> Enum.sort() ==
               ~w(allow_registrations edit_grace_minutes title)

      assert Enum.find(log, &(&1.details["key"] == "title")).details["value"] ==
               %{"before" => "Firefly", "after" => "Glowworm"}

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/log")
      |> assert_has("td.target a[href='/staff/settings']", text: "title")
    end

    test "rejects invalid values and saves nothing", %{conn: conn, admin: admin} do
      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/settings")
      |> fill_in("Title", with: "Glowworm")
      |> fill_in("Mentions per post", with: "-1")
      |> fill_in("Contact email", with: "nope")
      |> click_button("Save settings")
      |> assert_has("#flash-error", text: "nothing was saved")
      |> assert_has("p", text: "must be at least 0")
      |> assert_has("p", text: "must be a valid email")

      assert SiteSettings.get("title") == "Firefly"
      assert Repo.all(StaffAction) == []
    end
  end

  describe "the settings page's tools" do
    test "filters by category, search and changed only", %{conn: conn, admin: admin} do
      set(admin, %{"max_mentions" => "4"})

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/settings?category=Chat")
      |> assert_has("#setting-chat_enabled")
      |> refute_has("#setting-title")
      |> visit(~p"/staff/settings?q=mentions per post")
      |> assert_has("#setting-max_mentions")
      |> refute_has("#setting-chat_enabled")
      |> visit(~p"/staff/settings?changed=1")
      |> assert_has("#setting-max_mentions", text: "changed")
      |> refute_has("#setting-title")
      |> visit(~p"/staff/settings?q=zzzz")
      |> assert_has("#no-settings")
    end

    test "resets a setting and shows its history", %{conn: conn, admin: admin} do
      set(admin, %{"title" => "Glowworm"})

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/settings?q=title")
      |> click_button("#setting-title button", "History")
      |> assert_has("#history-title", text: "Firefly → Glowworm")
      |> click_button("#setting-title button", "Reset to default")
      |> assert_has("#flash-info", text: "title is back to its default.")

      assert SiteSettings.get("title") == "Firefly"
    end

    test "shows settings pinned by the environment read-only", %{conn: conn, admin: admin} do
      System.put_env("FIREFLY_SETTING_CONTACT_EMAIL", "ops@example.com")
      on_exit(fn -> System.delete_env("FIREFLY_SETTING_CONTACT_EMAIL") end)

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/settings?category=Basic")
      |> assert_has("#pinned-contact_email", text: "Set by FIREFLY_SETTING_CONTACT_EMAIL")
      |> assert_has("#settings_contact_email[disabled]")
    end

    test "keeps secrets out of the page, and a blank secret keeps it", %{conn: conn, admin: admin} do
      set(admin, %{"akismet_api_key" => "sekrit-key"})

      html = conn |> log_in_as(admin) |> get(~p"/staff/settings") |> html_response(200)
      refute html =~ "sekrit-key"

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/settings?category=Posting")
      |> click_button("Save settings")

      assert SiteSettings.get("akismet_api_key") == "sekrit-key"
    end

    test "exports JSON and YAML for admins only", %{conn: conn, admin: admin} do
      set(admin, %{"title" => "Glowworm", "akismet_api_key" => "sekrit"})

      json = conn |> log_in_as(admin) |> get(~p"/staff/settings/export/json")
      assert json.resp_body =~ ~s{"title": "Glowworm"}
      refute json.resp_body =~ "sekrit"
      assert get_resp_header(json, "content-disposition") |> hd() =~ ".json"

      yaml = conn |> log_in_as(admin) |> get(~p"/staff/settings/export/yaml")
      assert yaml.resp_body =~ ~s{title: "Glowworm"}

      refused = conn |> log_in_as(user_fixture()) |> get(~p"/staff/settings/export/json")
      assert redirected_to(refused) == "/"
    end

    @tag :tmp_dir
    test "imports a YAML file", %{conn: conn, admin: admin, tmp_dir: dir} do
      path = Path.join(dir, "settings.yaml")
      File.write!(path, "# from the old site\ntitle: \"Imported\"\nmax_mentions: 3\n")

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/settings")
      |> upload("Settings file", path)
      |> click_button("#import-form button", "Import")
      |> assert_has("#flash-info", text: "Imported 2 changed settings.")

      assert SiteSettings.get("title") == "Imported"
      assert SiteSettings.get("max_mentions") == 3
    end
  end

  describe "appearance" do
    @tag :tmp_dir
    test "admins upload a logo", %{conn: conn, admin: admin, tmp_dir: dir} do
      path = Firefly.UploadHelpers.image_file(dir, "logo.png")

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/settings?category=Basic")
      |> upload("Logo image", path)
      |> click_button("Use as logo")
      |> assert_has("#flash-info", text: "Logo saved.")
      |> assert_has("#site-logo")

      assert "/uploads/" <> _ = SiteSettings.get("logo_url")
    end

    test "the theme color and logo show on every page", %{conn: conn, admin: admin} do
      set(admin, %{"theme_color" => "#112233", "logo_url" => "/uploads/abc/logo.png"})

      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s{<meta name="theme-color" content="#112233">}
      conn |> visit(~p"/") |> assert_has("#site-logo[src='/uploads/abc/logo.png']")
    end
  end

  describe "site" do
    test "the title names the site in the layout, page titles and emails", %{
      conn: conn,
      admin: admin
    } do
      set(admin, %{"title" => "Glowworm"})

      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ "<title data-default=\"Glowworm\" data-suffix=\" - Glowworm\">"

      conn |> visit(~p"/") |> assert_has("header", text: "Glowworm")

      email = Emails.confirmation(admin, "https://example.com/confirm")
      assert email.subject == "Confirm your email address for Glowworm"
    end

    test "the description is shown on the home page and as a meta tag", %{
      conn: conn,
      admin: admin
    } do
      html = conn |> get(~p"/") |> html_response(200)
      refute html =~ ~s{name="description"}

      set(admin, %{"description" => "Talk about fireflies"})

      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ ~s{<meta name="description" content="Talk about fireflies">}
      conn |> visit(~p"/") |> assert_has("#site-description", text: "Talk about fireflies")
    end

    test "the contact email is linked from the sidebar", %{conn: conn, admin: admin} do
      conn |> visit(~p"/") |> refute_has("#contact-email")
      set(admin, %{"contact_email" => "staff@example.com"})
      conn |> visit(~p"/") |> assert_has("#contact-email[href='mailto:staff@example.com']")
    end
  end

  describe "registration" do
    test "closing it hides and blocks registration, GitHub sign-ups included", ctx do
      %{conn: conn, admin: admin} = ctx
      set(admin, %{"allow_registrations" => "false"})

      conn
      |> visit(~p"/login")
      |> refute_has("a", text: "Create Account")
      |> visit(~p"/register")
      |> assert_path(~p"/login")
      |> assert_has("#flash-error", text: "New registrations are closed.")

      assert {:error, :registration_closed} = register("newbie")

      assert {:error, "New registrations are closed."} =
               Firefly.Accounts.Auth.login(%{
                 provider: :github,
                 uid: 42,
                 nickname: "octo",
                 name: "Octo"
               })

      # Existing accounts still log in.
      set(admin, %{"allow_registrations" => "true"})

      {:ok, octo} =
        Firefly.Accounts.Auth.login(%{provider: :github, uid: 42, nickname: "octo", name: "Octo"})

      set(admin, %{"allow_registrations" => "false"})

      assert {:ok, ^octo} =
               Firefly.Accounts.Auth.login(%{provider: :github, uid: 42, nickname: "octo"})
    end

    test "without required confirmation, new accounts can post at once", %{admin: admin} do
      {:ok, confirming} = register("confirming")
      assert Posting.check(confirming) == {:error, :unconfirmed}

      set(admin, %{"require_email_confirmation" => "false"})
      {:ok, trusted} = register("trusted")
      assert Posting.check(trusted) == :ok
      # Also for accounts from before the change.
      assert Posting.check(confirming) == :ok
    end

    test "turning confirmation off never marks addresses verified", %{conn: conn, admin: admin} do
      set(admin, %{"require_email_confirmation" => "false"})
      {:ok, trusted} = register("trusted")
      refute Firefly.Accounts.User.confirmed?(trusted)

      conn
      |> log_in_as(trusted)
      |> visit(~p"/")
      |> refute_has("#confirm-email-notice")

      # Notification email still goes only to proven addresses.
      thread = thread_fixture(category_fixture("Mail"), admin, %{title: "Relay"})
      {:ok, _} = Discussion.create_post(thread, admin, %{body: "hello @trusted"})
      run_notifications()

      assert [%{kind: "mentioned"}] = Notifications.notifications_for(trusted)
      assert_no_email_sent()

      set(admin, %{"require_email_confirmation" => "true"})
      assert Posting.check(trusted) == {:error, :unconfirmed}

      conn
      |> log_in_as(trusted)
      |> visit(~p"/")
      |> assert_has("#confirm-email-notice")
    end
  end

  describe "spam and new users" do
    setup %{admin: admin} do
      member = user_fixture()
      thread = thread_fixture(category_fixture("Elixir"), admin, %{title: "Links"})
      %{member: member, thread: thread}
    end

    test "new-user link limit", %{admin: admin, thread: thread} do
      member = user_fixture(%{trust_level: 0})
      links = "https://a.example https://b.example"
      assert {:ok, _} = Discussion.create_post(thread, member, %{body: links})

      set(admin, %{"new_user_max_links" => "1"})
      assert {:error, changeset} = Discussion.create_post(thread, member, %{body: links})
      assert "new users can include at most 1 links per post" in errors_on(changeset).body
      assert Firefly.TrustLevels.new_user?(member)
    end

    test "max mentions", %{admin: admin, member: member, thread: thread} do
      set(admin, %{"max_mentions" => "1"})
      assert Mentions.max_mentions() == 1
      [a, b] = [user_fixture(), user_fixture()]
      body = "@#{a.username} and @#{b.username}"
      assert {:error, changeset} = Discussion.create_post(thread, member, %{body: body})
      assert "can mention at most 1 users" in errors_on(changeset).body
    end

    test "posts per minute keeps the configured window until set", %{admin: admin} do
      config = Application.get_env(:firefly, RateLimit)
      Application.put_env(:firefly, RateLimit, limits: [post: {20, :timer.minutes(10)}])
      on_exit(fn -> Application.put_env(:firefly, RateLimit, config) end)

      assert RateLimit.limit(:post) == {20, :timer.minutes(10)}
      set(admin, %{"posts_per_minute" => "7"})
      assert RateLimit.limit(:post) == {7, :timer.minutes(1)}
    end

    # Hammer windows are clock-aligned, so hitting a one-minute bucket twice
    # flakes when the run crosses hh:mm:00. Check the limit the gate uses
    # instead; RateLimitTest covers enforcement with a day-long window.
    test "posts per minute", %{admin: admin, member: member, thread: thread} do
      set(admin, %{"posts_per_minute" => "1"})
      assert RateLimit.limit(:post) == {1, :timer.minutes(1)}
      assert Posting.check(member, thread) == :ok
    end

    test "tags admin-only", %{admin: admin, member: member} do
      assert Discussion.may_create_tags?(member)
      set(admin, %{"tags_admin_only" => "true"})
      refute Discussion.may_create_tags?(member)
      assert Discussion.may_create_tags?(admin)
    end
  end

  describe "content" do
    test "max tags per thread", %{admin: admin} do
      category = category_fixture("Elixir")
      set(admin, %{"max_tags_per_thread" => "1"})
      assert Tag.max_per_thread() == 1

      assert {:error, changeset} =
               Discussion.create_thread(category, admin, %{
                 title: "Tagged",
                 body: "x",
                 tags: "otp beam"
               })

      assert "can have at most 1 tags" in errors_on(changeset).tags
    end

    test "the edit window limits how long authors can edit", %{admin: admin} do
      author = user_fixture()
      thread = thread_fixture(category_fixture("Elixir"), author, %{title: "Old"})
      [post] = Repo.preload(thread, :posts).posts
      old = %{post | inserted_at: NaiveDateTime.add(post.inserted_at, -2, :hour)}
      params = %{post: old, thread: thread}

      assert :ok = Policy.authorize(:edit_post, author, params)

      set(admin, %{"edit_grace_minutes" => "60"})
      assert {:error, :unauthorized} = Policy.authorize(:edit_post, author, params)
      assert :ok = Policy.authorize(:edit_post, author, %{params | post: post})
      assert :ok = Policy.authorize(:delete_post, author, params)
      assert :ok = Policy.authorize(:edit_post, admin, params)
    end
  end

  test "the cache is cleared on every node when settings change", %{admin: admin} do
    Application.put_env(:firefly, :site_settings_cache, true)

    on_exit(fn ->
      Application.put_env(:firefly, :site_settings_cache, false)
      SiteSettings.clear_cache()
    end)

    assert SiteSettings.get("title") == "Firefly"
    Repo.insert!(%Firefly.SiteSettings.SiteSetting{key: "title", value: "Behind the cache"})
    assert SiteSettings.get("title") == "Firefly"

    # Another node's change arrives over PubSub.
    Phoenix.PubSub.broadcast(Firefly.PubSub, SiteSettings.topic(), :site_settings_changed)
    :sys.get_state(Firefly.SiteSettings.Cache)
    assert SiteSettings.get("title") == "Behind the cache"

    # A change on this node applies at once.
    set(admin, %{"title" => "Glowworm"})
    assert SiteSettings.get("title") == "Glowworm"

    # A reader that loaded before a save and caches after it: its entry
    # belongs to the old generation and isn't served.
    generation = :persistent_term.get({SiteSettings, :generation})
    stale = SiteSettings.all()
    set(admin, %{"title" => "Lantern"})
    :persistent_term.put({SiteSettings, :values}, {generation, stale, MapSet.new()})
    assert SiteSettings.get("title") == "Lantern"
  end
end
