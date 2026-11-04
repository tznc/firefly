defmodule FireflyWeb.Locale do
  @moduledoc """
  The language the interface is shown in.

  A request's locale is the first of these that names a language Firefly
  has (`locales/0`):

    1. `?lang=` in the URL,
    2. the member's own choice (Settings > Interface),
    3. the session, which carries whatever an earlier request resolved,
    4. the browser's `Accept-Language`, best match first,
    5. the site's default (the `default_locale` site setting), else `en`.

  Each request writes its locale to the session, so a LiveView's first
  render (which can't read request headers) shows the same language, and
  a `?lang=` sticks for the links and form posts that follow.

  As a plug (after `fetch_session`) it sets the locale for the request
  (controllers and the dead render); `on_mount/4` does the same for a LiveView, from the session
  and the connected user. Both also assign `:locale` and `:text_dir`,
  which the root layout puts on `<html>`.

  Dates and times are formatted with `strftime/3`, whose month and day
  names are translated like everything else.
  """
  use Gettext, backend: FireflyWeb.Gettext

  @behaviour Plug

  import Plug.Conn

  @session_key "locale"

  @doc "Every locale the interface is translated into, the default first."
  def locales, do: Gettext.known_locales(FireflyWeb.Gettext)

  @doc "The locale's name in its own language, for pickers."
  def name(locale), do: Map.get(names(), locale, locale)

  @doc "Every locale as `{name, locale}` pairs, for a select."
  def options, do: Enum.map(locales(), &{name(&1), &1})

  defp names do
    %{
      "en" => "English",
      "es" => "Español",
      "fr" => "Français",
      "de" => "Deutsch",
      "pt_BR" => "Português (Brasil)",
      "ja" => "日本語",
      "zh_CN" => "简体中文",
      "ar" => "العربية"
    }
  end

  @doc "Locales written right to left."
  def rtl_locales, do: ~w(ar he fa ur)

  @doc "A locale's writing direction: `\"rtl\"` or `\"ltr\"`."
  def text_dir(locale), do: if(locale in rtl_locales(), do: "rtl", else: "ltr")

  @doc "The site's default locale (the `default_locale` setting, else `en`)."
  def default do
    case Firefly.SiteSettings.get("default_locale") do
      locale when is_binary(locale) -> known(locale) || "en"
      _unset -> "en"
    end
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    locale =
      known(conn.params["lang"]) || user_locale(conn) || from_session(conn) ||
        from_header(conn) || default()

    conn
    |> remember(locale)
    |> put(locale)
  end

  # `on_mount` for the live_session: the socket has the session (which the
  # plug has already resolved the browser's languages into) and, after
  # UserAuth's own hook, the current user.
  @doc false
  def on_mount(:put_locale, params, session, socket) do
    locale =
      known(params["lang"]) || user_locale(socket.assigns[:current_user]) ||
        known(session[@session_key]) || default()

    Gettext.put_locale(FireflyWeb.Gettext, locale)

    {:cont,
     socket
     |> Phoenix.Component.assign(:locale, locale)
     |> Phoenix.Component.assign(:text_dir, text_dir(locale))}
  end

  @doc "Sets the locale for this process and assigns it on the conn."
  def put(conn, locale) do
    Gettext.put_locale(FireflyWeb.Gettext, locale)

    conn
    |> assign(:locale, locale)
    |> assign(:text_dir, text_dir(locale))
  end

  defp user_locale(%Plug.Conn{} = conn), do: user_locale(conn.assigns[:current_user])
  defp user_locale(%{locale: locale}), do: known(locale)
  defp user_locale(_user), do: nil

  defp from_session(conn), do: known(get_session(conn, @session_key))

  # The session carries the request's locale to the LiveViews, which can't
  # read `Accept-Language` on their first render.
  defp remember(conn, locale) do
    if get_session(conn, @session_key) == locale,
      do: conn,
      else: put_session(conn, @session_key, locale)
  end

  # Accept-Language, best quality first ("fr-CA" matches "fr").
  defp from_header(conn) do
    conn
    |> get_req_header("accept-language")
    |> List.first()
    |> to_string()
    |> String.split(",")
    |> Enum.map(&parse_language/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.find_value(fn {tag, _quality} -> known(tag) end)
  end

  defp parse_language(part) do
    case String.split(String.trim(part), ";q=") do
      [""] -> nil
      [tag] -> {tag, 1.0}
      [tag, quality] -> {tag, parse_quality(quality)}
      _invalid -> nil
    end
  end

  defp parse_quality(quality) do
    case Float.parse(quality) do
      {value, _rest} -> value
      :error -> 0.0
    end
  end

  @doc """
  `locale` if Firefly has it, else nil. A language tag matches a locale
  that differs only in case or separator (`fr-CA` matches `fr`, `pt-br`
  matches `pt_BR`).
  """
  def known(nil), do: nil

  def known(locale) when is_binary(locale) do
    normalized = locale |> String.replace("-", "_") |> String.downcase()
    [language | _] = String.split(normalized, "_")

    Enum.find(locales(), &(String.downcase(&1) == normalized)) ||
      Enum.find(locales(), &(String.downcase(&1) == language))
  end

  def known(_locale), do: nil

  @doc """
  `Calendar.strftime/3` with the current locale's month and day names
  (translated in the `times` domain), so dates read in the reader's
  language without a CLDR dependency.
  """
  def strftime(datetime, format) do
    Calendar.strftime(datetime, format,
      month_names: fn month -> Enum.at(month_names(), month - 1) end,
      abbreviated_month_names: fn month -> Enum.at(abbreviated_month_names(), month - 1) end,
      day_of_week_names: fn day -> Enum.at(day_names(), day - 1) end,
      abbreviated_day_of_week_names: fn day -> Enum.at(abbreviated_day_names(), day - 1) end
    )
  end

  @doc "The months, January first, in the current locale."
  def month_names do
    [
      dgettext("times", "January"),
      dgettext("times", "February"),
      dgettext("times", "March"),
      dgettext("times", "April"),
      dgettext("times", "May"),
      dgettext("times", "June"),
      dgettext("times", "July"),
      dgettext("times", "August"),
      dgettext("times", "September"),
      dgettext("times", "October"),
      dgettext("times", "November"),
      dgettext("times", "December")
    ]
  end

  @doc "The months abbreviated, in the current locale."
  def abbreviated_month_names do
    [
      dgettext("times", "Jan"),
      dgettext("times", "Feb"),
      dgettext("times", "Mar"),
      dgettext("times", "Apr"),
      dgettext("times", "May (abbreviated)"),
      dgettext("times", "Jun"),
      dgettext("times", "Jul"),
      dgettext("times", "Aug"),
      dgettext("times", "Sep"),
      dgettext("times", "Oct"),
      dgettext("times", "Nov"),
      dgettext("times", "Dec")
    ]
  end

  @doc "The days, Monday first, in the current locale."
  def day_names do
    [
      dgettext("times", "Monday"),
      dgettext("times", "Tuesday"),
      dgettext("times", "Wednesday"),
      dgettext("times", "Thursday"),
      dgettext("times", "Friday"),
      dgettext("times", "Saturday"),
      dgettext("times", "Sunday")
    ]
  end

  @doc "The days abbreviated, Monday first, in the current locale."
  def abbreviated_day_names do
    [
      dgettext("times", "Mon"),
      dgettext("times", "Tue"),
      dgettext("times", "Wed"),
      dgettext("times", "Thu"),
      dgettext("times", "Fri"),
      dgettext("times", "Sat"),
      dgettext("times", "Sun")
    ]
  end
end
