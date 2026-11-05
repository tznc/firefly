defmodule Firefly.Themes do
  @moduledoc """
  The Themes context: themes and theme components admins build at
  `/staff/themes`, and which one each page uses.

  A theme (`Firefly.Themes.Theme`) sets the daisyUI color tokens of the
  light and dark schemes, adds CSS, and adds HTML to the page's head, the
  top of its body (header) and its end (footer). Theme components are
  themes too (`component: true`) that themes include: their colors, CSS
  and HTML come before the theme's own. Assets (images and fonts, see
  `Firefly.Themes.ThemeAsset`) are uploads the CSS names as
  `theme-asset(name)`.

  Everything a theme styles is compiled into one stylesheet on each
  change, served at a URL naming the theme's `version` (see `css_path/1`),
  so browsers keep it until the next change. The HTML is cleaned of
  scripts and event handlers (`Firefly.Themes.Scrubber`) unless an admin
  lets the theme run scripts (`set_allow_scripts/3`, staff-logged): its
  `<script>` tags then get the page's CSP nonce.

  The theme a page uses: the one an admin previews (just for them,
  `active/2`), else the member's pick among the `user_selectable` themes,
  else the `default_theme_id` site setting's (0: none, the built-in
  look). Color schemes are checked for contrast (`Firefly.Themes.Contrast`);
  shortfalls are warnings, not errors.

  Themes are shipped as packages, like plugins (see `Firefly.Packages`):
  installing one with a `theme` section creates or updates its themes
  here (`install_package/4`), linked to the package and stamped with a
  hash of what it set, so an upgrade can tell when an admin edited them
  since. A package's themes never run scripts; an admin's own themes can
  be exported as a package (`package_section/1`).

  Every change is staff-logged.
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [Theme, ThemeAsset, Palette, Contrast]

  import Ecto.Query

  alias Firefly.{Packages, Repo, SiteSettings, Uploads}
  alias Firefly.Accounts.User
  alias Firefly.Moderation.StaffLog
  alias Firefly.Themes.{Contrast, Palette, Scrubber, Theme, ThemeAsset}

  @cache {__MODULE__, :css}

  ## Reading

  @doc "Every theme (not components), by name, with their components."
  def list_themes, do: list(false)

  @doc "Every theme component, by name."
  def list_components, do: list(true)

  defp list(component?) do
    Repo.all(
      from(t in Theme, where: t.component == ^component?, order_by: t.name, preload: :components)
    )
  end

  @doc "The themes members may pick, by name."
  def selectable_themes do
    Repo.all(from(t in Theme, where: t.user_selectable and not t.component, order_by: t.name))
  end

  @doc "A theme or component by id, with its components and assets. Raises if there's none."
  def get_theme!(id), do: Theme |> Repo.get!(id) |> Repo.preload([:components, assets: :upload])

  @doc "A theme by id with its components, or nil."
  def get_theme(id) when is_integer(id) and id > 0,
    do: Theme |> Repo.get(id) |> Repo.preload(:components)

  def get_theme(_id), do: nil

  @doc "The site's default theme (the `default_theme_id` setting), or nil for the built-in look."
  def default_theme, do: get_theme(SiteSettings.get("default_theme_id"))

  @doc """
  The theme a page uses for `user` (nil: a visitor), with `preview_id` the
  theme an admin previews (from their session), or nil for the built-in
  look. See the moduledoc.
  """
  def active(user, preview_id \\ nil) do
    with nil <- preview(user, preview_id),
         nil <- user_theme(user) do
      default_theme()
    end
  end

  defp preview(%User{} = user, id) when is_integer(id) do
    if Bodyguard.permit?(Firefly.Discussion, :manage_themes, user, %{}),
      do: get_theme(id)
  end

  defp preview(_user, _id), do: nil

  defp user_theme(%User{theme_id: id}) when is_integer(id) do
    case get_theme(id) do
      %Theme{user_selectable: true, component: false} = theme -> theme
      _gone_or_not_selectable -> nil
    end
  end

  defp user_theme(_visitor), do: nil

  @doc "Sets the theme `user` picked (nil: the site's default). Only selectable themes."
  def select_for_user(%User{} = user, nil),
    do: user |> Ecto.Changeset.change(theme_id: nil) |> Repo.update()

  def select_for_user(%User{} = user, theme_id) do
    case get_theme(theme_id) do
      %Theme{user_selectable: true, component: false} ->
        user |> Ecto.Changeset.change(theme_id: theme_id) |> Repo.update()

      _other ->
        {:error, :not_selectable}
    end
  end

  ## The page's parts

  @doc "The path of `theme`'s compiled stylesheet (it changes with each version)."
  def css_path(%Theme{id: id, version: version}), do: "/theme-assets/#{id}/#{version}/theme.css"

  @doc """
  The compiled stylesheet of the theme with `id`, cached per version:
  `{:ok, version, css}` or `:error`.
  """
  def compiled_css(id) do
    case Repo.one(from(t in Theme, where: t.id == ^id, select: {t.version, t.updated_at})) do
      nil ->
        :error

      {version, _at} ->
        case :persistent_term.get({@cache, id}, nil) do
          {^version, css} ->
            {:ok, version, css}

          _stale ->
            css = Repo.one(from(t in Theme, where: t.id == ^id, select: t.compiled_css))
            :persistent_term.put({@cache, id}, {version, css})
            {:ok, version, css}
        end
    end
  end

  @doc """
  The HTML `theme` (and its components) adds to the page, by place
  (`:head`, `:header`, `:footer`): cleaned, or with `nonce` on its
  scripts when the theme may run them.
  """
  def html(%Theme{} = theme, place, nonce) when place in [:head, :header, :footer] do
    field = String.to_existing_atom("#{place}_html")

    Enum.map_join(
      theme.components ++ [theme],
      "\n",
      &prepare(Map.fetch!(&1, field), &1.allow_scripts, nonce)
    )
  end

  defp prepare(html, _scripts?, _nonce) when html in [nil, ""], do: ""
  # Scripts and styles go with their contents (the scrubber would keep the
  # text).
  defp prepare(html, false, _nonce),
    do: Scrubber.sanitize(Regex.replace(~r{<(script|style)\b[^>]*>.*?</\1\s*>}is, html, ""))

  defp prepare(html, true, nonce),
    do: Regex.replace(~r/<script\b(?![^>]*\bnonce=)/i, html, ~s{<script nonce="#{nonce}"})

  @doc "The color pairs below WCAG AA in `colors` (see `Firefly.Themes.Contrast`)."
  defdelegate contrast_warnings(colors), to: Contrast, as: :warnings

  ## Changing

  def change_theme(%Theme{} = theme, attrs \\ %{}), do: Theme.changeset(theme, attrs)

  @doc "Creates a theme (or component, `\"component\" => true`) as `admin`."
  def create_theme(attrs, %User{} = admin) do
    Repo.transact(fn ->
      with {:ok, theme} <- %Theme{} |> Theme.changeset(attrs) |> Repo.insert() do
        theme = compile!(theme)
        StaffLog.record(admin, "theme.create", {"theme", theme.id}, %{name: theme.name})
        {:ok, theme}
      end
    end)
  end

  @doc """
  Saves changes to `theme` as `admin`: a new version, compiled again (and
  so is every theme including it, when it's a component). Staff-logged
  with the fields that changed.
  """
  def update_theme(%Theme{} = theme, attrs, %User{} = admin) do
    changeset = Theme.changeset(theme, attrs)

    changed = changeset.changes |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()

    Repo.transact(fn ->
      with {:ok, updated} <- Repo.update(changeset) do
        log_changes(admin, updated, changed)
        {:ok, recompile!(updated)}
      end
    end)
  end

  defp log_changes(_admin, _theme, []), do: nil

  defp log_changes(admin, theme, changed),
    do: log(admin, "theme.update", theme, %{changed: changed})

  @doc """
  Lets `theme`'s HTML run scripts or not, as `admin` (an admin decision,
  staff-logged as `theme.allow_scripts`).
  """
  def set_allow_scripts(%Theme{package_id: id}, true, _admin) when is_integer(id),
    do: {:error, :package}

  def set_allow_scripts(%Theme{} = theme, allow?, %User{} = admin) when is_boolean(allow?) do
    Repo.transact(fn ->
      {:ok, updated} = theme |> Ecto.Changeset.change(allow_scripts: allow?) |> Repo.update()
      log(admin, "theme.allow_scripts", updated, %{allow_scripts: allow?})
      {:ok, recompile!(updated)}
    end)
  end

  @doc "Sets the components `theme` includes (ids of components) as `admin`."
  def set_components(%Theme{component: false} = theme, component_ids, %User{} = admin) do
    ids = for id <- List.wrap(component_ids), {id, ""} <- [Integer.parse(to_string(id))], do: id
    components = Repo.all(from(t in Theme, where: t.id in ^ids and t.component))

    Repo.transact(fn ->
      {:ok, updated} =
        theme
        |> Repo.preload(:components)
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_assoc(:components, components)
        |> Repo.update()

      log(admin, "theme.update", updated, %{components: Enum.map(components, & &1.name)})
      {:ok, recompile!(updated)}
    end)
  end

  def set_components(%Theme{}, _ids, _admin), do: {:error, :component}

  @doc "Deletes `theme` as `admin`; if it was the default, the built-in look is again."
  def delete_theme(%Theme{} = theme, %User{} = admin) do
    result =
      Repo.transact(fn ->
        Repo.delete!(theme)
        log(admin, "theme.delete", theme, %{})
        {:ok, theme}
      end)

    if SiteSettings.get("default_theme_id") == theme.id,
      do: {:ok, _} = SiteSettings.update(%{"default_theme_id" => "0"}, admin)

    :persistent_term.erase({@cache, theme.id})
    result
  end

  @doc "Makes `theme` the site's default (nil: the built-in look), as `admin`."
  def make_default(%Theme{component: true}, _admin), do: {:error, :component}

  def make_default(theme, %User{} = admin) do
    id = if theme, do: theme.id, else: 0
    SiteSettings.update(%{"default_theme_id" => to_string(id)}, admin)
  end

  @doc """
  Adds the file at `path` (an image or a WOFF/WOFF2 font, named
  `filename`) to `theme` as the asset `name`, as `admin`.
  """
  def add_asset(%Theme{} = theme, name, path, filename, %User{} = admin) do
    changeset = ThemeAsset.changeset(%ThemeAsset{theme_id: theme.id}, %{name: name})

    with {:ok, _valid} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, upload} <- Uploads.create(admin, path, filename, variant: "theme") do
      Repo.transact(fn -> insert_asset(theme, changeset, upload, admin) end)
    end
  end

  defp insert_asset(theme, changeset, upload, admin) do
    with {:ok, asset} <-
           changeset |> Ecto.Changeset.put_change(:upload_id, upload.id) |> Repo.insert() do
      log(admin, "theme.update", theme, %{asset: asset.name})
      recompile!(theme)
      {:ok, asset}
    end
  end

  @doc "Removes the asset with `asset_id` from `theme`, as `admin`."
  def remove_asset(%Theme{} = theme, asset_id, %User{} = admin) do
    case Repo.get_by(ThemeAsset, id: asset_id, theme_id: theme.id) do
      nil ->
        {:error, :not_found}

      asset ->
        Repo.transact(fn ->
          Repo.delete!(asset)
          log(admin, "theme.update", theme, %{removed_asset: asset.name})
          recompile!(theme)
          {:ok, asset}
        end)
    end
  end

  defp log(admin, action, theme, details),
    do: StaffLog.record(admin, action, {"theme", theme.id}, Map.put(details, :name, theme.name))

  ## Compiling

  # Bumps the version and compiles `theme`, then every theme including it.
  defp recompile!(%Theme{} = theme) do
    theme = compile!(theme, theme.version + 1)

    if theme.component do
      including =
        Repo.all(
          from(t in Theme,
            join: c in "theme_components",
            on: c.theme_id == t.id,
            where: c.component_id == ^theme.id
          )
        )

      Enum.each(including, &compile!(&1, &1.version + 1))
    end

    theme
  end

  # Compiles `theme` as version `version` (a new theme: its first).
  defp compile!(%Theme{} = theme, version \\ nil) do
    theme = Repo.preload(theme, [:components, assets: :upload], force: true)
    version = version || theme.version
    css = compile(%{theme | version: version})

    {:ok, compiled} =
      theme |> Ecto.Changeset.change(compiled_css: css, version: version) |> Repo.update()

    compiled
  end

  @doc """
  `theme`'s stylesheet (components, assets and colors loaded): its
  components' and its own color tokens as CSS variables on the
  `firefly`/`firefly-dark` data-themes, then their CSS, with
  `theme-asset(name)` turned into the asset's URL.
  """
  def compile(%Theme{} = theme) do
    parts = theme.components ++ [theme]
    assets = Map.new(theme.assets, &{&1.name, Uploads.url(&1.upload)})

    css =
      parts
      |> Enum.map_join("\n", &(&1.css || ""))
      |> then(
        &Regex.replace(~r/theme-asset\(\s*["']?([a-z0-9_-]+)["']?\s*\)/, &1, fn whole, name ->
          if url = assets[name], do: ~s{url("#{url}")}, else: whole
        end)
      )

    # "* /": removing "*/" would turn "**//" into another "*/".
    "/* #{String.replace(theme.name, "*/", "* /")} v#{theme.version} */\n" <>
      color_css(theme) <> settings_css(parts) <> css
  end

  # Package themes' settings, as custom properties (see Firefly.Packages).
  defp settings_css(parts) do
    case parts
         |> Enum.map(& &1.package_id)
         |> Enum.uniq()
         |> Enum.map(&Packages.css_variables/1)
         |> Enum.reject(&(&1 == "")) do
      [] -> ""
      variables -> ":root { #{Enum.join(variables, " ")} }\n"
    end
  end

  @doc """
  Only the colors of `theme`'s stylesheet: its components' and its own
  color tokens as CSS variables on the `firefly`/`firefly-dark`
  data-themes. For pages the theme's CSS isn't written for (the raw
  database admin).
  """
  def color_css(%Theme{} = theme) do
    theme = Repo.preload(theme, :components)
    parts = theme.components ++ [theme]

    Enum.map_join(Palette.schemes(), fn scheme ->
      tokens = Enum.reduce(parts, %{}, &Map.merge(&2, Map.get(&1.colors || %{}, scheme, %{})))

      variables =
        Enum.map_join(Enum.sort(tokens), " ", fn {token, value} ->
          "--color-#{token}: #{value};"
        end)

      if tokens == %{},
        do: "",
        else: "[data-theme=#{Palette.data_theme(scheme)}] { #{variables} }\n"
    end)
  end

  ## Packages

  @package_fields ~w(description colors css head_html header_html footer_html)a

  @doc """
  A hash of what a package sets on `theme`: its description, colors, CSS,
  HTML, components and asset names. It's stored when a package installs
  the theme, so a different one later means an admin edited it.
  """
  def content_hash(%Theme{} = theme) do
    theme = Repo.preload(theme, [:components, :assets], force: true)

    content = {
      Map.take(theme, @package_fields),
      theme.components |> Enum.map(& &1.id) |> Enum.sort(),
      theme.assets |> Enum.map(& &1.name) |> Enum.sort()
    }

    Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(content)), case: :lower)
  end

  @doc "Whether an admin changed `theme` since its package installed it."
  def locally_edited?(%Theme{package_hash: nil}), do: false
  def locally_edited?(%Theme{package_hash: hash} = theme), do: content_hash(theme) != hash

  @doc "The themes and components the package with row id `package_id` installed."
  def package_themes(package_id) do
    Repo.all(
      from(t in Theme, where: t.package_id == ^package_id, order_by: [t.component, t.name])
    )
  end

  @doc """
  Creates or updates the themes a package's `theme` section describes (see
  `Firefly.Packages`), for `package` (its row), as `admin`: its components
  first, then the theme including them. CSS, HTML and asset files come
  from `files`. Themes the package no longer has are deleted. A package's
  themes never run scripts. Run inside the install's transaction.
  """
  def install_package(section, files, package, %User{} = admin) do
    existing = Map.new(package_themes(package.id), &{&1.package_key, &1})

    components =
      for spec <- section["components"] || [] do
        name = spec["name"] || "#{section["name"] || package.name} component"
        spec = Map.put(spec, "component", true)

        put_package_theme(
          Map.put(spec, "name", name),
          "component:" <> name,
          files,
          package,
          existing,
          admin
        )
      end

    spec = Map.put_new(section, "name", package.name)
    theme = put_package_theme(spec, "theme", files, package, existing, admin)

    theme =
      if theme.component do
        theme
      else
        {:ok, theme} = set_components(theme, Enum.map(components, & &1.id), admin)
        theme
      end

    kept = MapSet.new([theme | components], & &1.id)

    for {_key, old} <- existing,
        not MapSet.member?(kept, old.id),
        do: {:ok, _} = delete_theme(old, admin)

    Enum.map([theme | components], &stamp!/1)
  end

  defp put_package_theme(spec, key, files, package, existing, admin) do
    attrs =
      %{
        "description" => spec["description"] || "",
        "component" => spec["component"] || false,
        "colors" => spec["colors"] || %{}
      }
      |> Map.merge(
        for(
          field <- ~w(css head_html header_html footer_html),
          into: %{},
          do: {field, files[spec[field]] || ""}
        )
      )

    theme =
      case existing[key] do
        nil ->
          attrs = Map.put(attrs, "name", unique_name(spec["name"]))

          %Theme{package_id: package.id, package_key: key}
          |> Theme.changeset(attrs)
          |> Repo.insert()
          |> package_saved!(admin, "theme.create", package)

        %Theme{} = theme ->
          theme
          |> Theme.changeset(attrs)
          |> Ecto.Changeset.change(allow_scripts: false)
          |> Repo.update()
          |> package_saved!(admin, "theme.update", package)
      end

    replace_assets!(theme, spec["assets"] || %{}, files, admin)
    recompile!(theme)
  end

  defp package_saved!({:ok, theme}, admin, action, package) do
    log(admin, action, theme, %{package: package.package_id, version: package.version})
    theme
  end

  defp package_saved!({:error, changeset}, _admin, _action, _package) do
    details =
      Enum.map_join(changeset.errors, "; ", fn {field, {text, _}} -> "#{field} #{text}" end)

    Repo.rollback("Its theme isn't valid: #{details}.")
  end

  # Sobelow: a new temporary directory; file names are reduced with Path.basename/1.
  # sobelow_skip ["Traversal.FileModule"]
  defp replace_assets!(theme, assets, files, admin) do
    Repo.delete_all(from(a in ThemeAsset, where: a.theme_id == ^theme.id))
    dir = Path.join(System.tmp_dir!(), "firefly-package-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    try do
      for {name, path} <- assets do
        file = Path.join(dir, Path.basename(path))
        File.write!(file, Map.fetch!(files, path))

        with {:ok, upload} <- Uploads.create(admin, file, Path.basename(path), variant: "theme"),
             {:ok, _asset} <-
               %ThemeAsset{theme_id: theme.id, upload_id: upload.id}
               |> ThemeAsset.changeset(%{name: name})
               |> Repo.insert() do
          :ok
        else
          _invalid -> Repo.rollback("Its asset #{name} isn't an image or font Firefly takes.")
        end
      end
    after
      File.rm_rf(dir)
    end
  end

  # Records what the package set, to tell local edits apart later.
  defp stamp!(theme) do
    {:ok, theme} =
      theme |> Ecto.Changeset.change(package_hash: content_hash(theme)) |> Repo.update()

    theme
  end

  @doc "Compiles the themes of the package with row id `package_id` again (its settings changed)."
  def recompile_package(package_id) do
    package_id |> package_themes() |> Enum.each(&recompile!/1)
  end

  @doc "Deletes the themes the package with row id `package_id` installed, as `admin`."
  def delete_package_themes(package_id, %User{} = admin) do
    for theme <- package_themes(package_id), do: {:ok, _} = delete_theme(theme, admin)
    :ok
  end

  @doc """
  `theme` as a package's theme section, with its files (CSS, HTML and
  assets): its components inline. Never whether it may run scripts.
  """
  def package_section(%Theme{} = theme) do
    theme = Repo.preload(theme, [components: [assets: :upload], assets: :upload], force: true)
    {section, files} = section(theme, "")

    {components, component_files} =
      theme.components
      |> Enum.with_index(1)
      |> Enum.map(fn {component, n} -> section(component, "components/#{n}/") end)
      |> Enum.unzip()

    section = if components == [], do: section, else: Map.put(section, "components", components)
    {section, Enum.reduce(component_files, files, &Map.merge(&2, &1))}
  end

  defp section(theme, dir) do
    texts =
      for {field, file} <- [
            css: "theme.css",
            head_html: "head.html",
            header_html: "header.html",
            footer_html: "footer.html"
          ],
          text = Map.fetch!(theme, field),
          text not in [nil, ""],
          do: {to_string(field), dir <> file, text}

    assets =
      for asset <- theme.assets,
          {:ok, data} <- [Uploads.contents(asset.upload)],
          do: {asset.name, "#{dir}assets/#{asset.name}/#{asset.upload.filename}", data}

    section =
      %{
        "name" => theme.name,
        "description" => theme.description || "",
        "component" => theme.component,
        "colors" => theme.colors || %{}
      }
      |> Map.merge(Map.new(texts, fn {key, path, _text} -> {key, path} end))
      |> Map.put("assets", Map.new(assets, fn {name, path, _data} -> {name, path} end))

    files = Map.new(texts, fn {_key, path, text} -> {path, text} end)
    {section, Map.merge(files, Map.new(assets, fn {_name, path, data} -> {path, data} end))}
  end

  # A theme named like an existing one gets a number.
  defp unique_name(name) do
    name = String.slice(String.trim(name), 0, 50)
    taken = MapSet.new(Repo.all(from(t in Theme, select: fragment("lower(?)", t.name))))

    Enum.find_value(Stream.iterate(1, &(&1 + 1)), fn
      1 -> if not MapSet.member?(taken, String.downcase(name)), do: name
      n -> if not MapSet.member?(taken, String.downcase("#{name} #{n}")), do: "#{name} #{n}"
    end)
  end

  @doc "A message for an error from this module."
  def message(:component), do: "That's a component: include it in a theme instead."
  def message(:not_selectable), do: "That theme can't be picked."
  def message(:not_found), do: "That's gone already."

  def message(:package),
    do:
      "Themes from packages never run scripts: export it and import it as your own to allow them."

  def message(message) when is_binary(message), do: message
end
