defmodule Firefly.Packages do
  @moduledoc """
  Packages: the one way plugins and themes are shipped and installed, at
  `/staff/packages`. Every package uploaded or fetched is listed here,
  per site; there is no outside catalog.

  A package is a versioned `.zip` with one manifest (`firefly.json`, see
  `Firefly.Plugin.Manifest`, read by `Firefly.Packages.Archive`) that
  carries plugin code, a `theme` section, or both, plus typed `settings`,
  `tags` and `dependencies`. A package with a theme carries the `theme`
  tag (and only then), so one list filtered by tag shows the themes:

      "theme": {
        "name": "Ocean",                     // default: the package's name
        "description": "Blue and calm.",
        "component": false,                  // true: a component themes include
        "colors": {"light": {"primary": "#0b6bcb"}, "dark": {...}},
        "css": "theme.css",                  // files in the package
        "head_html": "head.html", "header_html": "header.html", "footer_html": "footer.html",
        "assets": {"hero": "images/hero.png"}, // the CSS's theme-asset(hero)
        "components": [{...}]                // components it includes, same keys
      }

  This module owns their lifecycle for both kinds: reading an upload, or
  fetching one from a URL or a GitHub repository (SSRF-guarded, see
  `fetch/1`), size limits and checksums (`Firefly.Packages.Archive`),
  manifest validation, versions (an upgrade must be newer), dependencies
  across every package through `Firefly.Plugin.Graph`, uninstalling, and
  the staff log. The plugin part is then `Firefly.Plugins`'s (installed
  disabled, run sandboxed), the theme part `Firefly.Themes`' (themes
  created or updated, linked to the package). A package that is only a
  theme needs no sandbox.

  Upgrading a theme an admin edited since its package installed it needs
  `overwrite: true` (the confirm step). Theme JSON bundles from before
  packages still install, mapped into a package (`Firefly.Packages.Legacy`),
  and an admin's own theme exports as a package (`export_theme/1`).

  Plugins depend only on plugins (a dependency must be running for them
  to run); themes may depend on plugins and themes.

  ## Theme components from plugins

  A package with plugin code may also carry a theme component (`"theme":
  {"component": true, ...}`): colors and CSS for themes to include, its
  HTML cleaned like every package theme's (scripts never run, whatever
  the package says; only an admin's own themes may run them). Installing
  it needs its own grant (`grant_theme: true`, the confirm step's
  checkbox), recorded on the package and in the staff log
  (`package.theme_grant`); an upgrade of a granted package keeps it.

  ## Theme settings

  A theme package's typed `settings` (the plugin settings schema, see
  `Firefly.Plugin.Settings`) are set on its theme's page
  (`update_settings/3`) and reach its CSS as custom properties on `:root`,
  `--<package id>-<key>` (`css_variables/1`). A plugin package's settings
  are its plugin's, as before.
  """

  use Boundary, top_level?: true, check: [out: false], exports: [Package, Archive]

  alias Firefly.{Plugins, Repo, Themes}
  alias Firefly.Accounts.User
  alias Firefly.Moderation.StaffLog
  alias Firefly.Packages.{Archive, Legacy, Package}
  alias Firefly.Plugin.{Graph, Manifest, Settings}
  alias Firefly.Rendering.LinkPreviews.Fetcher
  alias Firefly.Themes.Theme

  @fetch_types ~w(application/zip application/x-zip-compressed application/octet-stream
                  application/json text/plain)

  ## Reading and fetching

  @doc """
  Reads an uploaded package (a `.zip`, or an old theme JSON bundle):
  `{:ok, archive}` or `{:error, message}`.
  """
  @spec read(binary) :: {:ok, Archive.t()} | {:error, String.t()}
  def read(data) when is_binary(data) do
    if Legacy.bundle?(data), do: Legacy.read(data), else: Archive.read(data)
  end

  @doc """
  Fetches the package at `url` and reads it: a package's (or an old theme
  bundle's) URL, or a GitHub repository's (`https://github.com/owner/repo`,
  whose default branch is the package, or holds an old
  `firefly-theme.json`). Public addresses only (see
  `Firefly.Rendering.LinkPreviews.Fetcher`), at most `Archive.max_size/0`.
  """
  def fetch(url) do
    with {:ok, package_url} <- package_url(String.trim(url || "")) do
      case Fetcher.get(package_url, types: @fetch_types, max_bytes: Archive.max_size()) do
        {:ok, %{body: body}} -> read(body)
        {:error, reason} -> {:error, "The package couldn't be fetched (#{inspect(reason)})."}
      end
    end
  end

  defp package_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: "github.com", path: "/" <> path} ->
        case String.split(String.trim_trailing(path, ".git"), "/", trim: true) do
          [owner, repo] -> {:ok, "https://codeload.github.com/#{owner}/#{repo}/zip/HEAD"}
          _other -> {:error, "Give the repository's address, like https://github.com/owner/repo."}
        end

      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        {:ok, url}

      _invalid ->
        {:error, "Give an http(s) URL."}
    end
  end

  ## The list

  @doc "The installed package `id` (its package id), or nil."
  def get(id), do: Repo.get_by(Package, package_id: id)

  @doc "The package that installed `theme`, or nil (an admin's own)."
  def for_theme(%Theme{package_id: nil}), do: nil
  def for_theme(%Theme{package_id: id}), do: Repo.get(Package, id)

  @doc """
  Every plugin and package, by name, for the staff list: `%{id, name,
  version, tags, kind, plugin, package, themes}`. `kind` is `:plugin` or
  `:theme`; `plugin` is the plugin as in `Firefly.Plugins.overview/0`
  (core plugins too), `themes` the themes (or a plugin's theme
  components) the package installed. With
  `tag`, only those that carry it.
  """
  def list(tag \\ nil) do
    packages = Map.new(Repo.all(Package), &{&1.package_id, &1})
    plugins = Plugins.overview()
    plugin_ids = MapSet.new(plugins, & &1.id)

    plugin_entries =
      for plugin <- plugins do
        %{
          id: plugin.id,
          name: plugin.name,
          version: plugin.version,
          tags: (plugin.manifest && plugin.manifest.tags) || [],
          kind: :plugin,
          plugin: plugin,
          package: packages[plugin.id],
          themes:
            if(package = packages[plugin.id], do: Themes.package_themes(package.id), else: [])
        }
      end

    theme_entries =
      for {id, package} <- packages, not MapSet.member?(plugin_ids, id) do
        %{
          id: id,
          name: package.name,
          version: package.version,
          tags: package.tags,
          kind: :theme,
          plugin: nil,
          package: package,
          themes: Themes.package_themes(package.id)
        }
      end

    (plugin_entries ++ theme_entries)
    |> Enum.filter(&(is_nil(tag) or tag in &1.tags))
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  @doc "Every tag the installed packages and plugins carry, sorted."
  def tags, do: list() |> Enum.flat_map(& &1.tags) |> Enum.uniq() |> Enum.sort()

  ## Install and upgrade

  @doc """
  What installing `archive` would do, for the confirm step: `%{archive,
  current, problems, edited}`: the installed package it upgrades (or
  nil), what stops it, and the names of the themes an admin edited since
  the installed version (an upgrade replaces their edits).
  """
  def preview(%Archive{manifest: manifest} = archive) do
    current = get(manifest.id)

    %{
      archive: archive,
      current: current,
      problems: problems(archive, current),
      edited: if(current, do: edited_themes(current), else: []),
      grant_needed: grant_needed?(manifest, current)
    }
  end

  # A plugin's theme components need staff's grant, once.
  defp grant_needed?(manifest, current) do
    Manifest.plugin?(manifest) and Manifest.theme?(manifest) and
      is_nil(current && current.theme_granted_at)
  end

  defp edited_themes(package) do
    for theme <- Themes.package_themes(package.id), Themes.locally_edited?(theme), do: theme.name
  end

  defp problems(%Archive{manifest: manifest} = archive, current) do
    plugin = Plugins.describe(manifest.id)

    cond do
      plugin && plugin.source == "core" ->
        ["#{manifest.id} is a core plugin; it can't be replaced by a package."]

      not plugin_theme_ok?(manifest) ->
        [
          "A plugin ships theme components only: its theme must be a component (\"component\": true), without components of its own."
        ]

      true ->
        case current && upgrade_problem(archive, current) do
          nil -> graph_problems(manifest)
          problem -> [problem]
        end
    end
  end

  defp plugin_theme_ok?(%Manifest{theme: theme} = manifest) do
    not (Manifest.plugin?(manifest) and Manifest.theme?(manifest)) or
      (theme["component"] == true and not Map.has_key?(theme, "components"))
  end

  defp upgrade_problem(%Archive{manifest: manifest} = archive, current) do
    cond do
      current.checksum == archive.checksum ->
        "This exact package is already installed."

      Version.compare(manifest.version, current.version) != :gt ->
        "Version #{current.version} is installed: install a newer version to upgrade."

      Manifest.plugin?(manifest) != Manifest.plugin?(parse!(current)) ->
        "Version #{current.version} is #{kind(parse!(current))}; a new version can't change that."

      true ->
        nil
    end
  end

  defp kind(manifest), do: if(Manifest.plugin?(manifest), do: "a plugin", else: "a theme")

  defp parse!(%Package{manifest: attrs}) do
    {:ok, manifest} = Manifest.parse(attrs, "upload")
    manifest
  end

  # Every installed package and plugin as a graph node.
  defp nodes do
    plugin_nodes = Plugins.graph_nodes()
    plugin_ids = MapSet.new(plugin_nodes, & &1.id)

    theme_nodes =
      for package <- Repo.all(Package),
          not MapSet.member?(plugin_ids, package.package_id),
          do: Graph.node(parse!(package))

    {plugin_nodes, theme_nodes}
  end

  # What installing `manifest` (or upgrading to it) would break: problems
  # the graph would have that it doesn't now. Plugins need plugins.
  defp graph_problems(manifest) do
    {plugin_nodes, theme_nodes} = nodes()
    nodes = plugin_nodes ++ theme_nodes
    theme_ids = MapSet.new(theme_nodes, & &1.id)
    before = Graph.problems(nodes)

    after_problems =
      Graph.problems(Enum.reject(nodes, &(&1.id == manifest.id)) ++ [Graph.node(manifest)])

    themes_needed =
      for id <- Map.keys(manifest.dependencies),
          Manifest.plugin?(manifest),
          MapSet.member?(theme_ids, id),
          do: "It's a plugin, so it can only depend on plugins, and #{id} is a theme."

    themes_needed ++
      for {id, problems} <- Enum.sort(after_problems),
          problem <- problems,
          problem not in Map.get(before, id, []),
          uniq: true do
        who = if id == manifest.id, do: "It", else: "Package #{id}"

        "#{who} #{Graph.describe(problem)}."
        |> String.replace(
          "but #{manifest.version} is installed",
          "but this is #{manifest.version}"
        )
      end
  end

  @doc """
  Installs `archive` as `admin`, or upgrades the installed package with
  its id. Options: `overwrite: true` to replace themes an admin edited
  since (see `preview/1`), `source_url` where it was fetched from.
  Returns `{:ok, package}` or `{:error, message}`.
  """
  def install(%Archive{} = archive, %User{} = admin, opts \\ []) do
    %{current: current, problems: problems, edited: edited, grant_needed: grant?} =
      preview(archive)

    cond do
      problems != [] ->
        {:error, Enum.join(problems, " ")}

      grant? and !opts[:grant_theme] ->
        {:error, "Its plugin ships theme components: allow them to install it."}

      edited != [] and !opts[:overwrite] ->
        {:error,
         "#{Enum.join(edited, ", ")} changed here since version #{current.version}: confirm to replace the changes."}

      true ->
        Repo.transact(fn -> save(archive, current, admin, opts) end)
    end
  end

  defp save(%Archive{manifest: manifest} = archive, current, admin, opts) do
    attrs = %{
      name: manifest.name,
      version: manifest.version,
      tags: manifest.tags,
      manifest: Manifest.to_map(manifest),
      archive: archive.zip,
      checksum: archive.checksum,
      source_url: opts[:source_url],
      installed_by_id: admin.id
    }

    grant? = Manifest.plugin?(manifest) and Manifest.theme?(manifest) and !!opts[:grant_theme]

    attrs =
      if grant? and is_nil(current && current.theme_granted_at),
        do:
          Map.merge(attrs, %{
            theme_granted_at: DateTime.utc_now(:second),
            theme_granted_by_id: admin.id
          }),
        else: attrs

    package =
      (current || %Package{package_id: manifest.id})
      |> Ecto.Changeset.change(attrs)
      |> Repo.insert_or_update!()

    if Map.has_key?(attrs, :theme_granted_at),
      do:
        StaffLog.record(admin, "package.theme_grant", {"package", package.id}, %{
          package: manifest.id,
          version: manifest.version,
          components: Enum.join(theme_names(manifest), ", ")
        })

    with :ok <- install_plugin(archive, package, admin),
         :ok <- install_theme(archive, package, admin) do
      {action, version} =
        if current,
          do: {"package.upgrade", %{before: current.version, after: manifest.version}},
          else: {"package.install", manifest.version}

      StaffLog.record(admin, action, {"package", package.id}, %{
        package: manifest.id,
        version: version,
        tags: Enum.join(manifest.tags, ", "),
        checksum: archive.checksum,
        source: opts[:source_url]
      })

      {:ok, package}
    end
  end

  defp install_plugin(%Archive{manifest: manifest} = archive, package, admin) do
    if Manifest.plugin?(manifest) do
      case Plugins.install(archive, package, admin) do
        {:ok, _row} -> :ok
        {:error, message} -> {:error, message}
      end
    else
      :ok
    end
  end

  defp install_theme(%Archive{manifest: %{theme: nil}}, _package, _admin), do: :ok

  defp install_theme(%Archive{manifest: manifest, files: files}, package, admin) do
    Themes.install_package(manifest.theme, files, package, admin)
    :ok
  end

  @doc "The names of the themes `manifest`'s theme section creates or updates."
  def theme_names(%Manifest{theme: nil}), do: []

  def theme_names(%Manifest{theme: theme, name: name}) do
    components = Enum.map(theme["components"] || [], &(&1["name"] || "#{name} component"))
    [theme["name"] || name | components]
  end

  ## Settings

  @doc """
  A theme package's settings: `{definitions, values}` (see
  `Firefly.Plugin.Settings`); none for a plugin's package, whose settings
  are its plugin's.
  """
  def settings(%Package{} = package) do
    manifest = parse!(package)

    if Manifest.plugin?(manifest),
      do: {[], %{}},
      else: {manifest.settings, Settings.values(manifest.settings, package.settings)}
  end

  @doc """
  Saves a theme package's settings from form `params` as `admin`, then
  compiles its themes again: `{:ok, package}` or `{:error, errors}` by key.
  """
  def update_settings(%Package{} = package, params, %User{} = admin) do
    {definitions, current} = settings(package)

    with {:ok, stored} <- Settings.cast_all(definitions, params) do
      values = Settings.values(definitions, stored)

      changes =
        for {key, value} <- values,
            value != current[key],
            into: %{},
            do: {key, %{before: current[key], after: value}}

      Repo.transact(fn -> save_settings(package, stored, changes, admin) end)
    end
  end

  defp save_settings(package, stored, changes, admin) do
    package = package |> Ecto.Changeset.change(settings: stored) |> Repo.update!()

    if changes != %{} do
      details = Map.put(changes, :package, package.package_id)
      StaffLog.record(admin, "package.settings", {"package", package.id}, details)
      Themes.recompile_package(package.id)
    end

    {:ok, package}
  end

  @doc """
  The CSS custom properties for the settings of the package with row id
  `id` (a theme's `package_id`): `--<package id>-<key>: value;` each, or
  "" when it has none. Text that could break out of a declaration is
  given as a CSS string instead.
  """
  def css_variables(nil), do: ""

  def css_variables(id) do
    with %Package{} = package <- Repo.get(Package, id),
         {[_ | _] = definitions, values} <- settings(package) do
      Enum.map_join(definitions, " ", fn %{key: key} ->
        "--#{package.package_id}-#{key}: #{css_value(values[key])};"
      end)
    else
      _none -> ""
    end
  end

  defp css_value(true), do: "1"
  defp css_value(false), do: "0"
  defp css_value(value) when is_integer(value), do: Integer.to_string(value)

  # Bare when it's simple and its brackets balance (an open one would take
  # in the rest of the stylesheet); else a string, escaping what would end
  # it (a quote, a backslash, and the newlines: \n, \r and \f) or the
  # page's <style>.
  defp css_value(value) when is_binary(value) do
    if value =~ ~r{\A[#%(),./\w\s+-]*\z} and balanced?(value),
      do: value,
      else: ~s{"} <> String.replace(value, ~r{[\\"\n\r\f<>]}, &"\\#{Base.encode16(&1)} ") <> ~s{"}
  end

  # By code point: a combining mark after "(" makes one grapheme of them.
  defp balanced?(value) do
    value
    |> String.codepoints()
    |> Enum.reduce_while(0, fn
      "(", depth -> {:cont, depth + 1}
      ")", 0 -> {:halt, -1}
      ")", depth -> {:cont, depth - 1}
      _char, depth -> {:cont, depth}
    end)
    |> Kernel.==(0)
  end

  ## Uninstall

  @doc """
  Whether `id` (a package, or an uploaded plugin) can be uninstalled:
  `:ok`, or `{:error, message}` (core plugins can't be; nor can a package
  others need).
  """
  def uninstall_check(id) do
    {plugin_nodes, theme_nodes} = nodes()

    needed_by =
      for node <- plugin_nodes ++ theme_nodes, Map.has_key?(node.requires, id), do: node.id

    plugin = Plugins.describe(id)

    cond do
      is_nil(plugin) and is_nil(get(id)) ->
        {:error, "No package #{id} is installed."}

      plugin && plugin.source == "core" ->
        {:error, "Core plugins can't be uninstalled, only disabled."}

      needed_by != [] ->
        {:error, "#{Enum.join(needed_by, ", ")} need it: uninstall them first."}

      true ->
        :ok
    end
  end

  @doc """
  Uninstalls `id` as `admin` (see `uninstall_check/1`): its plugin (with
  its data, see `Firefly.Plugins.uninstall/2`) and its themes.
  """
  def uninstall(id, %User{} = admin) do
    with :ok <- uninstall_check(id),
         :ok <- if(Plugins.describe(id), do: Plugins.uninstall(id, admin), else: :ok) do
      if package = get(id), do: remove(package, admin)
      :ok
    end
  end

  defp remove(package, admin) do
    {:ok, _} =
      Repo.transact(fn ->
        Themes.delete_package_themes(package.id, admin)
        Repo.delete!(package)

        {:ok,
         StaffLog.record(admin, "package.uninstall", {"package", package.id}, %{
           package: package.package_id,
           version: package.version
         })}
      end)
  end

  ## Export

  @doc """
  `theme` (with its components and assets) as a package: `{filename,
  zip}`. A theme that came from a package keeps its id and version; an
  admin's own gets an id from its name and version 1.0.0.
  """
  def export_theme(%Theme{} = theme) do
    {section, files} = Themes.package_section(theme)
    package = for_theme(theme)
    id = if package, do: package.package_id, else: Legacy.id(theme.name)

    manifest = %{
      "id" => id,
      "name" => String.slice(theme.name, 0, 100),
      "version" => if(package, do: package.version, else: "1.0.0"),
      "firefly" => "~> 1.0",
      "description" => String.slice(theme.description || "", 0, 500),
      "tags" => ["theme"],
      "theme" => section
    }

    {"#{id}.zip", Archive.build(manifest, files)}
  end
end
