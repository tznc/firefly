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

    test "the partial translations cover the navigation at least" do
      path = Path.join([@gettext, "ar", "LC_MESSAGES", "default.po"])
      translated = Map.new(translations(path))

      for msgid <- ["Categories", "Latest", "Log in", "Search", "Settings", "Tags"] do
        assert Map.get(translated, msgid, "") != "", "ar is missing #{inspect(msgid)}"
      end
    end

    # msgid to its msgstr (the first plural form for plurals).
    defp translations(path) do
      for [_, msgid, msgstr] <-
            Regex.scan(
              ~r/^msgid "((?:[^"\\]|\\.)*)"\n(?:msgid_plural "(?:[^"\\]|\\.)*"\n)?msgstr(?:\[0\])? "((?:[^"\\]|\\.)*)"/m,
              File.read!(path)
            ),
          msgid != "" do
        {msgid, msgstr}
      end
    end

    defp msgids(path), do: path |> translations() |> MapSet.new(&elem(&1, 0))
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
