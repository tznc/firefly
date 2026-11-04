defmodule Firefly.SiteSettingsCatalogTest do
  use Firefly.DataCase
  use Bamboo.Test, shared: true

  import Firefly.Fixtures

  alias Firefly.{Accounts, Chat, Discussion, RateLimit, SiteSettings, Uploads}
  alias Firefly.Accounts.User
  alias Firefly.Moderation.StaffAction
  alias Firefly.SiteSettings.Transfer

  setup do
    on_exit(&SiteSettings.clear_cache/0)
    %{admin: admin_fixture(%{username: "boss"})}
  end

  defp set(admin, settings), do: {:ok, _} = SiteSettings.update(settings, admin)

  describe "the catalog" do
    test "every setting is complete, unique, categorized and has a valid default" do
      definitions = SiteSettings.definitions()
      assert length(definitions) > 175

      keys = Enum.map(definitions, & &1.key)
      assert keys == Enum.uniq(keys)
      categories = Enum.map(SiteSettings.categories(), &elem(&1, 0))

      for definition <- definitions do
        assert definition.category in categories, definition.key
        assert definition.subcategory == definition.section
        assert definition.label != "" and definition.help != "", definition.key
        assert definition.env =~ ~r/^FIREFLY_[A-Z0-9_]+$/

        assert SiteSettings.cast(definition, encode(definition.default)) ==
                 {:ok, definition.default},
               "#{definition.key}'s default doesn't pass its own validation"
      end
    end

    # Each setting must do something: its key appears in code outside the
    # settings module, literally or as a prefix the code completes
    # ("rate_limit_#{bucket}", "saml_" <> key).
    test "every setting is read somewhere" do
      root = Path.expand("../..", __DIR__)

      sources =
        Path.wildcard(Path.join(root, "*/lib/**/*.{ex,heex}"))
        |> Enum.reject(&String.ends_with?(&1, "/firefly/site_settings.ex"))
        |> Enum.map(&File.read!/1)
        |> Enum.join("\n")

      literals = MapSet.new(Regex.scan(~r/"([a-z0-9_]+)"/, sources), &Enum.at(&1, 1))

      prefixes =
        Enum.map(Regex.scan(~r/"([a-z][a-z0-9_]{3,})(?:#\{|" <>)/, sources), &Enum.at(&1, 1))

      unread =
        for %{key: key} <- SiteSettings.definitions(),
            not MapSet.member?(literals, key),
            not Enum.any?(prefixes, &String.starts_with?(key, &1)),
            do: key

      assert unread == [], "settings nothing reads: #{inspect(unread)}"
    end

    defp encode(value) when is_list(value), do: Enum.join(value, ",")
    defp encode(value), do: to_string(value)
  end

  describe "types" do
    test "lists, colors and uploads are validated" do
      list = SiteSettings.definition("authorized_extensions")
      assert SiteSettings.cast(list, "png, pdf,\npng") == {:ok, ["png", "pdf"]}
      assert {:error, "may only hold " <> _} = SiteSettings.cast(list, "exe")

      color = SiteSettings.definition("theme_color")
      assert SiteSettings.cast(color, " #ABCDEF ") == {:ok, "#abcdef"}
      assert {:error, _} = SiteSettings.cast(color, "red")

      upload = SiteSettings.definition("logo_url")

      assert SiteSettings.cast(upload, "/uploads/abc_D-1/logo.png") ==
               {:ok, "/uploads/abc_D-1/logo.png"}

      assert {:error, _} = SiteSettings.cast(upload, "https://evil.example/x.png")
    end
  end

  describe "environment pins, resets and history" do
    test "a pinned setting takes the environment's value and can't be changed", %{admin: admin} do
      System.put_env("FIREFLY_SETTING_TITLE", "Pinned")
      on_exit(fn -> System.delete_env("FIREFLY_SETTING_TITLE") end)

      assert SiteSettings.get("title") == "Pinned"
      assert SiteSettings.env_override("title") == "FIREFLY_SETTING_TITLE"
      assert SiteSettings.env_override("description") == nil

      assert {:error, %{"title" => "is set by FIREFLY_SETTING_TITLE"}} =
               SiteSettings.update(%{"title" => "Other"}, admin)

      # Posting the pinned value itself (an unchanged form) is fine.
      assert {:ok, %{}} = SiteSettings.update(%{"title" => "Pinned"}, admin)
    end

    test "reset goes back to the default and history shows every change", %{admin: admin} do
      set(admin, %{"title" => "One"})
      set(admin, %{"title" => "Two"})
      assert {:ok, :reset} = SiteSettings.reset("title", admin)
      assert SiteSettings.get("title") == "Firefly"
      refute SiteSettings.customized?("title")
      assert {:ok, :unchanged} = SiteSettings.reset("title", admin)

      assert [reset, two, one] = SiteSettings.history("title")
      assert {reset.before, reset.after, reset.reset} == {"Two", "Firefly", true}
      assert {two.before, two.after} == {"One", "Two"}
      assert one.actor.id == admin.id
    end

    test "secrets stay out of the history", %{admin: admin} do
      set(admin, %{"akismet_api_key" => "sekrit"})
      [change] = SiteSettings.history("akismet_api_key")
      assert change.after == "[secret]"
    end
  end

  describe "import and export" do
    # Found by Firefly.SiteSettingsPropertyTest: values that aren't text or
    # lists of text (an object, a nested list) raised in to_string/1.
    test "an import with values of the wrong shape is refused", %{admin: admin} do
      assert {:error, errors} =
               Transfer.import(%{"title" => %{"a" => 1}, "reserved_usernames" => [[nil]]}, admin)

      assert errors == %{"title" => "is invalid", "reserved_usernames" => "is invalid"}
    end

    # Found by Firefly.SiteSettingsPropertyTest: a list item holding a
    # comma was kept whole, then stored joined with commas and read back
    # as two items.
    test "list items split on commas however they come", %{admin: admin} do
      set(admin, %{"reserved_usernames" => ["support,staff", "help"]})
      assert SiteSettings.get("reserved_usernames") == ["support", "staff", "help"]
    end

    test "round-trips changed settings through JSON and YAML, never secrets", %{admin: admin} do
      set(admin, %{
        "title" => "Glow \"worm\"",
        "max_mentions" => "4",
        "chat_enabled" => "false",
        "reserved_usernames" => "support, staff",
        "akismet_api_key" => "sekrit"
      })

      map = Transfer.export_map()
      assert map["title"] == ~s{Glow "worm"}
      assert map["reserved_usernames"] == ["support", "staff"]
      refute Map.has_key?(map, "akismet_api_key")
      refute Map.has_key?(map, "description")
      assert Map.has_key?(Transfer.export_map(all: true), "description")

      json = IO.iodata_to_binary(Transfer.export(:json))
      yaml = IO.iodata_to_binary(Transfer.export(:yaml))
      assert {:ok, ^map} = Transfer.parse(json)
      assert {:ok, ^map} = Transfer.parse(yaml)

      for key <- Map.keys(map), do: {:ok, _} = SiteSettings.reset(key, admin)
      assert SiteSettings.get("max_mentions") == 10

      {:ok, settings} = Transfer.parse(yaml <> "\nnot_a_setting: 1\n")

      assert {:ok, %{changed: changed, skipped: ["not_a_setting"]}} =
               Transfer.import(settings, admin)

      assert "max_mentions" in changed
      assert SiteSettings.get("max_mentions") == 4
      assert SiteSettings.get("reserved_usernames") == ["support", "staff"]
    end

    test "imports nothing when a value is invalid", %{admin: admin} do
      {:ok, settings} = Transfer.parse("title: \"Ok\"\nmax_mentions: -5\n")
      assert {:error, %{"max_mentions" => _}} = Transfer.import(settings, admin)
      assert SiteSettings.get("title") == "Firefly"
      assert {:error, "Line 1 " <> _} = Transfer.parse("just some text")
    end
  end

  describe "the new settings do what they say" do
    test "registration rules", %{admin: admin} do
      set(admin, %{
        "min_username_length" => "5",
        "reserved_usernames" => "Support",
        "min_password_length" => "12"
      })

      register = fn username, password ->
        Accounts.register_user(%{
          username: username,
          email: "#{username}@example.com",
          password: password
        })
      end

      assert {:error, changeset} = register.("abc", "long-enough-pass")
      assert errors_on(changeset).username != []
      assert {:error, changeset} = register.("support", "long-enough-pass")
      assert "is reserved" in errors_on(changeset).username
      assert {:error, changeset} = register.("someone", "short-pass")
      assert errors_on(changeset).password != []
      assert {:ok, _} = register.("someone", "long-enough-pass")
    end

    test "new members start with the defaults", %{admin: admin} do
      set(admin, %{
        "default_email_notifications" => "false",
        "default_reply_level" => "normal",
        "default_keyboard_shortcuts" => "false"
      })

      {:ok, user} =
        Accounts.register_user(%{
          username: "fresh",
          email: "fresh@example.com",
          password: "password1"
        })

      assert %User{email_notifications: false, reply_level: "normal", keyboard_shortcuts: false} =
               user
    end

    test "post and chat lengths", %{admin: admin} do
      set(admin, %{"max_post_length" => "500", "max_chat_message_length" => "100"})
      category = category_fixture()

      assert {:error, _} =
               Discussion.create_thread(category, admin, %{
                 title: "Long",
                 body: String.duplicate("a", 501)
               })

      assert Chat.Message.max_length() == 100
      changeset = Chat.Message.changeset(%Chat.Message{}, %{body: String.duplicate("b", 101)})
      refute changeset.valid?
    end

    @tag :tmp_dir
    test "only the allowed file types can be attached", %{admin: admin, tmp_dir: dir} do
      set(admin, %{"authorized_extensions" => "png, jpg"})
      assert Uploads.accept() == [".png", ".jpg", ".jpeg"]
      path = Firefly.UploadHelpers.file(dir, "notes.txt", "hello")

      assert {:error, "That file type isn't allowed here."} =
               Uploads.create(admin, path, "notes.txt")
    end

    test "rate limits and the sender name", %{admin: admin} do
      configured = RateLimit.limit(:like)
      set(admin, %{"rate_limit_like" => "7", "email_from_name" => "Glow Team"})
      assert RateLimit.limit(:like) == {7, elem(configured, 1)}

      email = Firefly.Notifications.Emails.test_email("x@example.com")
      assert {"Glow Team", _address} = email.from
    end

    test "link lifetimes show in the emails", %{admin: admin} do
      set(admin, %{"magic_link_minutes" => "30", "password_reset_hours" => "2"})
      user = user_fixture()
      assert Firefly.Notifications.Emails.magic_link(user, "u").text_body =~ "30 minutes"
      assert Firefly.Notifications.Emails.password_reset(user, "u").text_body =~ "2 hours"
    end

    test "every change is staff-logged", %{admin: admin} do
      set(admin, %{"theme_color" => "#112233"})
      assert [%{details: %{"key" => "theme_color"}}] = Repo.all(StaffAction)
    end
  end
end
