defmodule FirestormWeb.Web.SiteSettingsTest do
  use FirestormWeb.Web.ConnCase

  import Ecto.Query, only: [from: 2]
  import FirestormWeb.DataCase, only: [errors_on: 1]

  alias FirestormWeb.{Emails, Forums, Mentions, Posting, Repo, SiteSettings}
  alias FirestormWeb.Forums.{Policy, SpamGuard, StaffAction, Tag}

  setup do
    %{admin: admin_fixture(%{username: "boss"})}
  end

  defp set(admin, settings), do: {:ok, _} = SiteSettings.update(settings, admin)

  defp register(username) do
    Forums.register_user(%{
      username: username,
      email: "#{username}@example.com",
      password: "password1"
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
             "new_user_hours" => 24,
             "max_mentions" => 10,
             "tags_admin_only" => false,
             "max_tags_per_thread" => 5,
             "edit_grace_minutes" => 0
           } = SiteSettings.all()

    # Seeded from the deployment's config
    assert SiteSettings.get("posts_per_minute") == 1_000
    Application.put_env(:firestorm_web, :tags_admin_only, true)
    on_exit(fn -> Application.delete_env(:firestorm_web, :tags_admin_only) end)
    assert SiteSettings.get("tags_admin_only")
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
               Forums.login_or_register_from_github(%{uid: 42, nickname: "octo", name: "Octo"})

      # Existing accounts still log in.
      set(admin, %{"allow_registrations" => "true"})

      {:ok, octo} =
        Forums.login_or_register_from_github(%{uid: 42, nickname: "octo", name: "Octo"})

      set(admin, %{"allow_registrations" => "false"})
      assert {:ok, ^octo} = Forums.login_or_register_from_github(%{uid: 42, nickname: "octo"})
    end

    test "without required confirmation, new accounts can post at once", %{admin: admin} do
      {:ok, confirming} = register("confirming")
      assert Posting.check(confirming) == {:error, :unconfirmed}

      set(admin, %{"require_email_confirmation" => "false"})
      {:ok, trusted} = register("trusted")
      assert Posting.check(trusted) == :ok
    end
  end

  describe "spam and new users" do
    setup %{admin: admin} do
      member = user_fixture()
      thread = thread_fixture(category_fixture("Elixir"), admin, %{title: "Links"})
      %{member: member, thread: thread}
    end

    test "new-user link limit and period", %{admin: admin, member: member, thread: thread} do
      links = "https://a.example https://b.example"
      assert {:ok, _} = Forums.create_post(thread, member, %{body: links})

      set(admin, %{"new_user_max_links" => "1"})
      assert {:error, changeset} = Forums.create_post(thread, member, %{body: links})
      assert "new accounts can include at most 1 links per post" in errors_on(changeset).body

      # With a zero-hour period, only the post count keeps an account new.
      set(admin, %{"new_user_hours" => "0"})
      assert SpamGuard.new_user?(member)
      for n <- 1..3, do: {:ok, _} = Forums.create_post(thread, member, %{body: "post #{n}"})
      refute SpamGuard.new_user?(member)
    end

    test "max mentions", %{admin: admin, member: member, thread: thread} do
      set(admin, %{"max_mentions" => "1"})
      assert Mentions.max_mentions() == 1
      assert {:error, changeset} = Forums.create_post(thread, member, %{body: "@a and @b"})
      assert "can mention at most 1 users" in errors_on(changeset).body
    end

    test "posts per minute", %{admin: admin, member: member, thread: thread} do
      set(admin, %{"posts_per_minute" => "1"})
      assert Posting.check(member, thread) == :ok
      assert Posting.check(member, thread) == {:error, :rate_limited}
    end

    test "tags admin-only", %{admin: admin, member: member} do
      assert Forums.may_create_tags?(member)
      set(admin, %{"tags_admin_only" => "true"})
      refute Forums.may_create_tags?(member)
      assert Forums.may_create_tags?(admin)
    end
  end

  describe "content" do
    test "max tags per thread", %{admin: admin} do
      category = category_fixture("Elixir")
      set(admin, %{"max_tags_per_thread" => "1"})
      assert Tag.max_per_thread() == 1

      assert {:error, changeset} =
               Forums.create_thread(category, admin, %{
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
    Application.put_env(:firestorm_web, :site_settings_cache, true)

    on_exit(fn ->
      Application.put_env(:firestorm_web, :site_settings_cache, false)
      SiteSettings.clear_cache()
    end)

    assert SiteSettings.get("title") == "Firefly"
    Repo.insert!(%FirestormWeb.Forums.SiteSetting{key: "title", value: "Behind the cache"})
    assert SiteSettings.get("title") == "Firefly"

    # Another node's change arrives over PubSub.
    Phoenix.PubSub.broadcast(FirestormWeb.PubSub, SiteSettings.topic(), :site_settings_changed)
    :sys.get_state(FirestormWeb.SiteSettings.Cache)
    assert SiteSettings.get("title") == "Behind the cache"

    # A change on this node applies at once.
    set(admin, %{"title" => "Glowworm"})
    assert SiteSettings.get("title") == "Glowworm"
  end
end
