defmodule FireflyWeb.I18nTest do
  use FireflyWeb.ConnCase, async: false

  alias Firefly.{Accounts, SiteSettings}
  alias FireflyWeb.Locale

  setup do
    on_exit(fn ->
      SiteSettings.clear_cache()
      Gettext.put_locale(FireflyWeb.Gettext, "en")
    end)

    :ok
  end

  describe "picking the locale" do
    test "?lang wins and is remembered for the next request", %{conn: conn} do
      conn = get(conn, ~p"/?lang=fr")
      assert html_response(conn, 200) =~ ~s{<html lang="fr"}
      assert get_session(conn, "locale") == "fr"

      # The session carries it without the parameter.
      assert conn |> recycle() |> get(~p"/") |> html_response(200) =~ ~s{<html lang="fr"}
    end

    test "a member's own choice beats their browser", %{conn: conn} do
      user = user_fixture()
      {:ok, user} = Accounts.update_preferences(user, %{locale: "de"})

      html =
        conn
        |> log_in_as(user)
        |> put_req_header("accept-language", "fr-FR,fr;q=0.9")
        |> get(~p"/")
        |> html_response(200)

      assert html =~ ~s{<html lang="de"}
    end

    test "Accept-Language is matched by quality, and by language alone", %{conn: conn} do
      assert conn
             |> put_req_header("accept-language", "nl;q=0.9,pt-BR;q=0.8,fr;q=0.2")
             |> get(~p"/")
             |> html_response(200) =~ ~s{<html lang="pt_BR"}

      assert conn
             |> put_req_header("accept-language", "fr-CA")
             |> get(~p"/")
             |> html_response(200) =~ ~s{<html lang="fr"}
    end

    test "falls back to the site's default, and ignores unknown languages", %{conn: conn} do
      admin = admin_fixture()
      {:ok, _} = SiteSettings.update(%{"default_locale" => "es"}, admin)

      assert conn
             |> put_req_header("accept-language", "kl-GL")
             |> get(~p"/")
             |> html_response(200) =~ ~s{<html lang="es"}

      assert conn |> get(~p"/?lang=klingon") |> html_response(200) =~ ~s{<html lang="es"}
    end

    test "a right-to-left locale sets dir on the document", %{conn: conn} do
      html = conn |> get(~p"/?lang=ar") |> html_response(200)
      assert html =~ ~s{lang="ar"}
      assert html =~ ~s{dir="rtl"}
      assert conn |> get(~p"/?lang=en") |> html_response(200) =~ ~s{dir="ltr"}
    end

    test "known/1 normalizes tags" do
      assert Locale.known("pt-br") == "pt_BR"
      assert Locale.known("ZH_cn") == "zh_CN"
      assert Locale.known("de-AT") == "de"
      assert Locale.known("tlh") == nil
      assert Locale.known(nil) == nil
    end
  end

  describe "the translated interface" do
    test "the chrome is in the reader's language", %{conn: conn} do
      html = conn |> get(~p"/?lang=fr") |> html_response(200)
      assert html =~ "Catégories"
      assert html =~ "Se connecter"
      assert html =~ "Rechercher"

      spanish = conn |> get(~p"/?lang=es") |> html_response(200)
      assert spanish =~ "Categorías"
      assert spanish =~ "Iniciar sesión"
    end

    test "a LiveView keeps the locale once it connects", %{conn: conn} do
      conn
      |> visit(~p"/login?lang=de")
      |> assert_has("a", text: "Konto erstellen")
      |> click_link("Mit Passwort anmelden")
      |> assert_has("button", text: "Anmelden")
    end

    test "form errors are translated", %{conn: conn} do
      conn
      |> visit(~p"/register?lang=es")
      |> fill_in("Nombre de usuario", with: "")
      |> fill_in("Correo electrónico", with: "nope")
      |> click_button("Crear cuenta")
      |> assert_has("#registration-form", text: "no puede estar vacío")
    end

    test "members pick their language in their settings", %{conn: conn} do
      user = user_fixture()

      conn
      |> log_in_as(user)
      |> visit(~p"/settings/interface")
      |> select("Language", option: "Français")
      |> click_button("Save")

      assert Accounts.get_user!(user.id).locale == "fr"
    end

    test "dates are written in the reader's language" do
      date = ~U[2026-03-09 10:00:00Z]

      Gettext.put_locale(FireflyWeb.Gettext, "fr")
      assert Locale.strftime(date, "%A %-d %B") == "lundi 9 mars"

      Gettext.put_locale(FireflyWeb.Gettext, "ja")
      assert Locale.strftime(date, "%B%-d日") == "3月9日"
    end
  end

  describe "the translations themselves" do
    @gettext Path.join([__DIR__, "..", "priv", "gettext"]) |> Path.expand()
    # Arabic is a partial translation on purpose (see the README): it has
    # the interface's chrome, not every sentence yet.
    @partial ["ar"]

    test "every locale has a file for every domain" do
      domains =
        @gettext |> Path.join("*.pot") |> Path.wildcard() |> Enum.map(&Path.basename(&1, ".pot"))

      assert "default" in domains

      for locale <- Locale.locales(), domain <- domains do
        path = Path.join([@gettext, locale, "LC_MESSAGES", "#{domain}.po"])
        assert File.exists?(path), "#{locale} is missing #{domain}.po"
      end
    end

    test "no .po file is missing a message its .pot has, or has one it doesn't" do
      for domain <- ["default", "errors", "times"] do
        template = msgids(Path.join(@gettext, "#{domain}.pot"))

        for locale <- Locale.locales() do
          translated = msgids(Path.join([@gettext, locale, "LC_MESSAGES", "#{domain}.po"]))

          assert MapSet.difference(template, translated) |> MapSet.to_list() == [],
                 "#{locale}/#{domain}.po is missing messages (run mix gettext.extract --merge)"

          assert MapSet.difference(translated, template) |> MapSet.to_list() == [],
                 "#{locale}/#{domain}.po has messages the template doesn't"
        end
      end
    end

    test "every message is translated, except English (which is the source) and the partials" do
      for domain <- ["default", "errors", "times"],
          locale <- Locale.locales() -- ["en" | @partial] do
        path = Path.join([@gettext, locale, "LC_MESSAGES", "#{domain}.po"])
        untranslated = for {msgid, ""} <- translations(path), do: msgid

        assert untranslated == [],
               "#{locale}/#{domain}.po has untranslated messages: #{inspect(untranslated)}"
      end
    end

    # Text that genuinely reads the same in a language: technical names,
    # code, and the words a language borrowed from English.
    @same_everywhere ~w(API CSS HTML JSON YAML OK Firefly GitHub hero)
    @same_in %{
      "es" => ~w(Chat Normal Scripts Webhooks),
      "fr" =>
        ["Notifications (%{count})", "version %{version}"] ++
          ~w(Actions Badges Communication Configuration Description Forum Maintenance Messages Points
             Normal Notifications Scripts Webhooks),
      "de" =>
        ["Link (optional)"] ++
          ~w(April August Backups Browser Chat Forum Import Moderation Name Normal November Plugins
             September Status Tags Uploads URLs Webhooks Website),
      "pt_BR" => ~w(Backups Chat Normal Plugins Posts Scripts Status Tags Webhooks),
      "ar" => ~w(Webhooks)
    }

    test "no translation is left fuzzy or copied from the English" do
      for domain <- ["default", "errors", "times"], locale <- Locale.locales() -- ["en"] do
        path = Path.join([@gettext, locale, "LC_MESSAGES", "#{domain}.po"])
        same = @same_everywhere ++ Map.get(@same_in, locale, [])

        fuzzy = for {msgid, flags, _} <- entries(path), "fuzzy" in flags, do: msgid

        copied =
          for {msgid, _, msgstr} <- entries(path),
              msgstr == msgid,
              msgid not in same,
              not String.starts_with?(msgid, ["http://", "https://"]),
              do: msgid

        assert fuzzy == [], "#{locale}/#{domain}.po has fuzzy messages: #{inspect(fuzzy)}"

        assert copied == [],
               "#{locale}/#{domain}.po has English left as the translation " <>
                 "(translate it, or list it here if it really reads the same): #{inspect(copied)}"
      end
    end

    test "translations keep the message's %{...} placeholders" do
      placeholders = &(~r/%\{\w+\}/ |> Regex.scan(&1) |> List.flatten() |> Enum.sort())

      for domain <- ["default", "errors", "times"], locale <- Locale.locales() -- ["en"] do
        path = Path.join([@gettext, locale, "LC_MESSAGES", "#{domain}.po"])

        # Plurals are left out: a singular form may spell out the 1.
        broken =
          for {msgid, _, msgstr} <- entries(path, plurals: false),
              msgstr != "",
              placeholders.(msgstr) != placeholders.(msgid),
              do: {msgid, msgstr}

        assert broken == [], "#{locale}/#{domain}.po changes placeholders: #{inspect(broken)}"
      end
    end

    test "the partial translations cover the navigation at least" do
      path = Path.join([@gettext, "ar", "LC_MESSAGES", "default.po"])
      translated = Map.new(translations(path))

      for msgid <- ["Categories", "Latest", "Log in", "Search", "Settings", "Tags"] do
        assert Map.get(translated, msgid, "") != "", "ar is missing #{inspect(msgid)}"
      end
    end

    # msgid to its msgstr (the first plural form for plurals).
    defp translations(path), do: path |> File.read!() |> translations_in()

    defp msgids(path), do: path |> translations() |> MapSet.new(&elem(&1, 0))

    # Each message as {msgid, flags, msgstr} (the first plural form for plurals).
    defp entries(path, opts \\ []) do
      plurals? = Keyword.get(opts, :plurals, true)

      for block <- path |> File.read!() |> String.split("\n\n"),
          plurals? or not String.contains?(block, "\nmsgid_plural "),
          {msgid, msgstr} <- translations_in(block) do
        flags =
          case Regex.run(~r/^#,(.*)$/m, block) do
            [_, flags] -> flags |> String.split(",") |> Enum.map(&String.trim/1)
            nil -> []
          end

        {msgid, flags, msgstr}
      end
    end

    defp translations_in(block) do
      for [_, msgid, msgstr] <-
            Regex.scan(
              ~r/^msgid "((?:[^"\\]|\\.)*)"\n(?:msgid_plural "(?:[^"\\]|\\.)*"\n)?msgstr(?:\[0\])? "((?:[^"\\]|\\.)*)"/m,
              block
            ),
          msgid != "" do
        {msgid, msgstr}
      end
    end
  end

  describe "the localized templates" do
    # The files whose user-facing text is extracted into Gettext. The
    # localized surface grows file by file; this list is the contract, and
    # the test below keeps English literals from creeping back into it.
    @localized [
      "lib/firefly_web/components/layouts.ex",
      "lib/firefly_web/components/layouts/root.html.heex",
      "lib/firefly_web/live/auth_live/forgot_password.ex",
      "lib/firefly_web/live/auth_live/identity.ex",
      "lib/firefly_web/live/auth_live/login.ex",
      "lib/firefly_web/live/auth_live/magic_link.ex",
      "lib/firefly_web/live/auth_live/registration.ex",
      "lib/firefly_web/live/auth_live/reset_password.ex",
      "lib/firefly_web/live/staff_live/categories.ex",
      "lib/firefly_web/live/staff_live/emails.ex",
      "lib/firefly_web/live/staff_live/groups.ex",
      "lib/firefly_web/live/staff_live/index.ex",
      "lib/firefly_web/live/staff_live/screening.ex",
      "lib/firefly_web/live/staff_live/settings.ex",
      "lib/firefly_web/live/staff_live/theme.ex",
      "lib/firefly_web/live/staff_live/themes.ex",
      "lib/firefly_web/live/staff_live/user.ex",
      "lib/firefly_web/live/staff_live/users.ex"
    ]

    @attributes ~w(label placeholder aria-label title prompt)

    # Names that read the same in every language.
    @brands ~w(DiscourseConnect Firefly Firestorm GitHub Google Apple Discord Slack Webhooks)

    test "hold no user-facing text outside gettext" do
      app = Path.expand(Path.join(__DIR__, ".."))

      violations =
        for file <- @localized,
            source = File.read!(Path.join(app, file)),
            {snippet, reason} <- literals(source, Path.extname(file)) do
          "#{file}: #{reason} #{inspect(snippet)}"
        end

      assert violations == [],
             "wrap these in gettext(...):\n" <> Enum.join(violations, "\n")
    end

    # Literal text in markup: an attribute that reaches the reader, or a
    # line of prose between tags. Only the markup is searched, not
    # module docs or code.
    defp literals(source, extension) do
      markup = if extension == ".heex", do: [source], else: heex_blocks(source)

      Enum.flat_map(markup, fn block ->
        attributes =
          for attribute <- @attributes,
              [_, value] <- Regex.scan(~r/\b#{attribute}="([^"{}]*[A-Za-z]{2}[^"{}]*)"/, block),
              do: {value, "literal #{attribute}"}

        text =
          for [_, line] <- Regex.scan(~r/^\s*([A-Z][A-Za-z][^<>{}"\n]*)$/m, block),
              String.match?(line, ~r/[A-Za-z]{3}/),
              String.trim(line) not in @brands,
              do: {String.trim(line), "literal text"}

        attributes ++ text
      end)
    end

    # The contents of each ~H""" ... """ sigil.
    defp heex_blocks(source) do
      ~r/~H"""\n(.*?)\n\s*"""/s
      |> Regex.scan(source)
      |> Enum.map(fn [_, block] -> block end)
    end
  end
end
