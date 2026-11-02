defmodule FirestormWeb.Plugins do
  @moduledoc """
  Installed plugins (see `FirestormWeb.Plugin`): which there are, which are
  active and in what order, and their lifecycle, managed by staff at
  `/staff/plugins`.

  Two sources feed it: core plugins, the modules in

      config :firestorm_web, FirestormWeb.Plugins, core: [...]

  (enabled unless staff disable them), and uploaded bundles stored in
  `plugins` (installed disabled). Either kind can depend on the other.

  ## Dependencies

  Manifests declare `dependencies` and `optional_dependencies` with version
  requirements (see `FirestormWeb.Plugin.Graph`). An install or upgrade
  that would leave any plugin with a missing or incompatible dependency, or
  make a cycle, is refused with what's wrong. A plugin is *active* when it's
  enabled, has no problems, and every required dependency is active;
  plugins load and their hooks run in dependency order (`active/0`), with
  `priority` breaking ties.

    * Enabling a plugin enables the disabled plugins it needs
      (`enable_plan/1` lists them for the confirm step).
    * Disabling one disables, after the same confirm, the enabled plugins
      that need it (`disable_plan/1`).
    * Uninstalling one that others need is refused, naming them.
    * When the circuit breaker turns a plugin off (`trip/2`), the plugins
      that need it are *suspended*: still enabled, but inactive until it's
      enabled again, when they resume.

  Every change is staff-logged, cascades with their cause.

  ## Caching

  `active/0` is served from `:persistent_term` and reloaded after a change,
  on every node through PubSub (see `FirestormWeb.Plugins.Registry`), so
  changes apply everywhere without a restart. Like site settings, the
  cache is off in tests (`config :firestorm_web, :plugins_cache`).
  """

  import Ecto.Query

  require Logger

  alias FirestormWeb.{Forums, Plugin, Repo, StaffLog}
  alias FirestormWeb.Forums.User
  alias FirestormWeb.Plugin.{Bundle, Graph, Manifest, Runner, Sandboxed, Settings}
  alias FirestormWeb.Plugins.{Health, InstalledPlugin}

  @pubsub FirestormWeb.PubSub
  @topic "plugins"
  @cache_key {__MODULE__, :active}
  @generation_key {__MODULE__, :generation}

  @doc false
  def topic, do: @topic

  @doc "The core plugin modules from config."
  def core_modules, do: Application.get_env(:firestorm_web, __MODULE__, [])[:core] || []

  ## Loading

  # Every installed plugin, loaded: `%{id, source, module, row, manifest,
  # state, error, enabled, disabled_reason}`, by id. `manifest` is nil (and
  # `error` says why) when the plugin can't load.
  defp entries do
    rows = Map.new(Repo.all(InstalledPlugin), &{&1.plugin_id, &1})
    core = Enum.map(core_modules(), &core_entry(&1, rows))
    core_ids = MapSet.new(core, & &1.id)

    uploads =
      for row <- Map.values(rows), row.source == "upload" do
        entry = load_entry(row.plugin_id, "upload", Sandboxed, row, row)

        if MapSet.member?(core_ids, row.plugin_id),
          do: %{entry | manifest: nil, error: "Its id is taken by a core plugin."},
          else: entry
      end

    Map.new(core ++ Enum.reject(uploads, &MapSet.member?(core_ids, &1.id)), &{&1.id, &1})
  end

  defp core_entry(module, rows) do
    case safe_load(module, nil) do
      {:ok, manifest, _state} -> load_entry(manifest.id, "core", module, rows[manifest.id], nil)
      {:error, message} -> broken_entry(inspect(module), module, message)
    end
  end

  defp load_entry(id, source, module, row, spec) do
    case safe_load(module, spec) do
      {:ok, %Manifest{id: ^id} = manifest, state} ->
        %{
          id: id,
          source: source,
          module: module,
          row: row,
          manifest: manifest,
          state: state,
          error: nil,
          # Core plugins are on until staff turn them off.
          enabled: if(row, do: row.enabled, else: source == "core"),
          disabled_reason: row && row.disabled_reason
        }

      {:ok, _manifest, _state} ->
        %{broken_entry(id, module, "Its manifest names another id.") | row: row}

      {:error, message} ->
        %{broken_entry(id, module, message) | row: row, source: source}
    end
  end

  defp broken_entry(id, module, message) do
    %{
      id: id,
      source: "core",
      module: module,
      row: nil,
      manifest: nil,
      state: nil,
      error: message,
      enabled: false,
      disabled_reason: nil
    }
  end

  defp safe_load(module, spec) do
    module.load(spec)
  rescue
    error -> {:error, "It failed to load: " <> Exception.message(error)}
  end

  # The installed plugins with their dependency problems, order and the
  # active ones.
  defp snapshot do
    entries = entries()
    nodes = for {_id, %{manifest: %Manifest{} = manifest}} <- entries, do: Graph.node(manifest)
    problems = Graph.problems(nodes)
    order = Graph.order(nodes)

    active =
      Enum.reduce(order, MapSet.new(), fn id, active ->
        entry = entries[id]

        if entry.enabled and is_nil(entry.disabled_reason) and not Map.has_key?(problems, id) and
             Enum.all?(Map.keys(entry.manifest.dependencies), &MapSet.member?(active, &1)),
           do: MapSet.put(active, id),
           else: active
      end)

    %{entries: entries, nodes: nodes, problems: problems, order: order, active: active}
  end

  @doc """
  The active plugins, loaded, in the order their hooks run: dependencies
  first, then by priority.
  """
  @spec active() :: [Plugin.t()]
  def active, do: cached(&load_active/0)

  defp load_active do
    snapshot = snapshot()

    for id <- snapshot.order, MapSet.member?(snapshot.active, id) do
      entry = snapshot.entries[id]

      %Plugin{
        id: id,
        module: entry.module,
        manifest: entry.manifest,
        state: entry.state,
        source: entry.source,
        settings: Settings.values(entry.manifest.settings, entry.row && entry.row.settings)
      }
    end
  end

  @doc "The active plugin `id`, or nil."
  def get_active(id), do: Enum.find(active(), &(&1.id == id))

  @doc "The active plugins implementing `hook`, in order."
  def implementing(hook), do: Enum.filter(active(), &Plugin.implements?(&1, hook))

  defp cached(load) do
    if Application.get_env(:firestorm_web, :plugins_cache, true) do
      generation = :persistent_term.get(@generation_key, nil)

      case :persistent_term.get(@cache_key, nil) do
        {^generation, plugins} ->
          plugins

        _missing_or_stale ->
          plugins = load.()
          :persistent_term.put(@cache_key, {generation, plugins})
          plugins
      end
    else
      load.()
    end
  end

  @doc false
  def clear_cache, do: :persistent_term.put(@generation_key, make_ref())

  # After a change commits: reload here, and on every other node.
  defp changed do
    clear_cache()
    Phoenix.PubSub.broadcast_from(@pubsub, self(), @topic, :plugins_changed)
  end

  ## Cross-plugin calls

  @doc """
  `caller` calls `function`, exported by plugin `target`, with `args`.
  Allowed only when `caller` depends on `target` (required or optional),
  `target` is active and exports `function`. Through the host only: a
  sandboxed plugin never touches another's instance.
  """
  def call_export(%Plugin{} = caller, target, function, args) do
    with {:ok, plugin} <- export_target(caller, target, function) do
      case Runner.invoke(plugin, "call_export", [function, args]) do
        {:ok, value} -> {:ok, value}
        {:error, message} when is_binary(message) -> {:error, message}
        {:error, {kind, _message}} -> {:error, "plugin #{target} failed: #{kind}"}
      end
    end
  end

  defp export_target(caller, target, function) do
    declared =
      Map.has_key?(caller.manifest.dependencies, target) or
        Map.has_key?(caller.manifest.optional_dependencies, target)

    plugin = declared && get_active(target)

    cond do
      not declared ->
        {:error, "#{caller.id} doesn't depend on #{target}"}

      is_nil(plugin) ->
        {:error, "plugin #{target} isn't active"}

      function not in plugin.manifest.exports ->
        {:error, "plugin #{target} doesn't export #{function}"}

      true ->
        {:ok, plugin}
    end
  end

  ## Overview

  @doc """
  Every installed plugin for the staff pages, in load order (plugins that
  can't load last): `%{id, name, version, source, manifest, status,
  problems, dependencies, dependents, stats, row}`. `status` is `:enabled`,
  `:disabled`, `{:auto_disabled, reason}`, `{:suspended, ids}` (enabled but
  waiting for those plugins) or `:broken`.
  """
  def overview do
    snapshot = snapshot()
    broken = for {id, %{manifest: nil}} <- snapshot.entries, do: id
    Enum.map(snapshot.order ++ Enum.sort(broken), &describe(snapshot, &1))
  end

  @doc "One plugin as in `overview/0`, or nil if it isn't installed."
  def describe(id) do
    snapshot = snapshot()
    if Map.has_key?(snapshot.entries, id), do: describe(snapshot, id)
  end

  defp describe(snapshot, id) do
    entry = snapshot.entries[id]
    manifest = entry.manifest

    problems =
      if entry.error,
        do: [entry.error],
        else: Enum.map(Map.get(snapshot.problems, id, []), &Graph.describe/1)

    Map.merge(about(entry), %{
      id: id,
      source: entry.source,
      manifest: manifest,
      row: entry.row,
      status: status(snapshot, entry, problems),
      problems: problems,
      dependencies: dependencies(snapshot, manifest),
      dependents:
        for(
          node <- snapshot.nodes,
          Map.has_key?(node.requires, id) or Map.has_key?(node.optional, id),
          do: node.id
        ),
      stats: Health.stats(id)
    })
  end

  defp about(%{manifest: nil} = entry),
    do: %{name: entry.id, version: entry.row && entry.row.version, settings: nil}

  defp about(%{manifest: manifest, row: row}) do
    %{
      name: manifest.name,
      version: manifest.version,
      settings: Settings.values(manifest.settings, row && row.settings)
    }
  end

  defp status(snapshot, entry, problems) do
    cond do
      MapSet.member?(snapshot.active, entry.id) -> :enabled
      entry.disabled_reason -> {:auto_disabled, entry.disabled_reason}
      problems != [] -> :broken
      not entry.enabled -> :disabled
      true -> {:suspended, inactive_requirements(snapshot, entry.manifest)}
    end
  end

  defp inactive_requirements(snapshot, manifest),
    do:
      Enum.reject(
        Enum.sort(Map.keys(manifest.dependencies)),
        &MapSet.member?(snapshot.active, &1)
      )

  defp dependencies(_snapshot, nil), do: []

  defp dependencies(snapshot, manifest) do
    for {dep, requirement, optional} <- Manifest.requirements(manifest) do
      state =
        case snapshot.entries[dep] do
          %{manifest: %Manifest{version: version}} ->
            dependency_state(snapshot, dep, version, requirement)

          _ ->
            :missing
        end

      %{id: dep, requirement: requirement, optional: optional, state: state}
    end
  end

  defp dependency_state(snapshot, dep, version, requirement) do
    cond do
      not Version.match?(version, requirement) -> {:incompatible, version}
      MapSet.member?(snapshot.active, dep) -> :active
      true -> :inactive
    end
  end

  ## Install and upgrade

  @doc """
  Reads an uploaded bundle for the install step: `{:ok, preview}` with the
  bundle, the installed version it would upgrade (or nil) and the problems
  that would stop it, or `{:error, message}` if it isn't a valid bundle.
  """
  def preview(zip) do
    with {:ok, bundle} <- Bundle.read(zip) do
      snapshot = snapshot()
      current = snapshot.entries[bundle.manifest.id]

      {:ok,
       %{
         bundle: bundle,
         current: current && describe(snapshot, current.id),
         problems: install_problems(snapshot, bundle, current)
       }}
    end
  end

  defp install_problems(snapshot, %Bundle{manifest: manifest}, nil),
    do: graph_problems(snapshot, manifest)

  defp install_problems(snapshot, %Bundle{manifest: manifest} = bundle, current) do
    cond do
      current.source == "core" ->
        ["#{manifest.id} is a core plugin; it can't be replaced by an upload."]

      current.row.checksum == bundle.checksum ->
        ["This exact bundle is already installed."]

      current.manifest && Version.compare(manifest.version, current.manifest.version) != :gt ->
        ["Version #{current.manifest.version} is installed: upload a newer version to upgrade."]

      true ->
        graph_problems(snapshot, manifest)
    end
  end

  # What installing `manifest` (or upgrading to it) would break: problems
  # the graph would have that it doesn't now.
  defp graph_problems(snapshot, manifest) do
    nodes = Enum.reject(snapshot.nodes, &(&1.id == manifest.id)) ++ [Graph.node(manifest)]
    after_problems = Graph.problems(nodes)

    for {id, problems} <- Enum.sort(after_problems),
        problem <- problems,
        problem not in Map.get(snapshot.problems, id, []) do
      who = if id == manifest.id, do: "It", else: "Plugin #{id}"
      "#{who} #{Graph.describe(problem)}."
    end
    |> Enum.map(
      &String.replace(
        &1,
        "but #{manifest.version} is installed",
        "but this is #{manifest.version}"
      )
    )
    |> Enum.uniq()
  end

  @doc """
  Installs `bundle` as `admin`, or upgrades the installed plugin with its
  id (keeping its settings and state). A new plugin starts disabled.
  """
  def install(%Bundle{manifest: manifest} = bundle, %User{} = admin) do
    snapshot = snapshot()
    current = snapshot.entries[manifest.id]

    case install_problems(snapshot, bundle, current) do
      [] -> save_bundle(bundle, current, admin)
      problems -> {:error, Enum.join(problems, " ")}
    end
  end

  defp save_bundle(bundle, current, admin) do
    manifest = bundle.manifest
    row = (current && current.row) || %InstalledPlugin{plugin_id: manifest.id, source: "upload"}

    attrs = %{
      version: manifest.version,
      manifest: Manifest.to_map(manifest),
      bundle: bundle.zip,
      checksum: bundle.checksum,
      code: Bundle.code(bundle),
      installed_by_id: admin.id
    }

    # A fresh install starts with a clean slate; an upgrade keeps its history.
    if is_nil(current), do: Health.clear(manifest.id)

    {:ok, row} =
      Repo.transact(fn ->
        row = Repo.insert_or_update!(Ecto.Changeset.change(row, attrs))

        {action, details} =
          if current,
            do:
              {"plugin.upgrade",
               %{version: %{before: current.row.version, after: manifest.version}}},
            else: {"plugin.install", %{version: manifest.version}}

        StaffLog.record(
          admin,
          action,
          {"plugin", row.id},
          Map.merge(details, %{
            plugin: manifest.id,
            permissions: Enum.join(manifest.permissions, ", "),
            checksum: bundle.checksum
          })
        )

        {:ok, row}
      end)

    changed()
    {:ok, row}
  end

  ## Enable, disable, uninstall

  @doc """
  What enabling `id` takes: `{:ok, ids}`, the plugin and the disabled
  plugins it needs, dependencies first; or `{:error, message}` if it can't
  be enabled.
  """
  def enable_plan(id) do
    snapshot = snapshot()

    with {:ok, entry} <- fetch(snapshot, id) do
      needed = Enum.reverse(Graph.requirements_of(snapshot.nodes, id))
      ids = Enum.filter(needed ++ [id], &off?(snapshot.entries[&1]))
      problems = Enum.flat_map(ids, &Map.get(snapshot.problems, &1, []))

      cond do
        entry.error ->
          {:error, entry.error}

        problems != [] ->
          {:error, "It #{Enum.map_join(Enum.uniq(problems), "; ", &Graph.describe/1)}."}

        true ->
          {:ok, ids}
      end
    end
  end

  defp off?(entry), do: not entry.enabled or not is_nil(entry.disabled_reason)

  @doc """
  What disabling `id` takes: `{:ok, ids}`, the plugin and the enabled
  plugins that need it.
  """
  def disable_plan(id) do
    snapshot = snapshot()

    with {:ok, _entry} <- fetch(snapshot, id) do
      dependents = Graph.dependents_of(snapshot.nodes, id)
      {:ok, [id | Enum.filter(dependents, &snapshot.entries[&1].enabled)]}
    end
  end

  @doc """
  Whether `id` can be uninstalled: `:ok`, or `{:error, message}` (core
  plugins can't be; nor can a plugin others need).
  """
  def uninstall_check(id) do
    snapshot = snapshot()

    with {:ok, entry} <- fetch(snapshot, id) do
      needed_by = for node <- snapshot.nodes, Map.has_key?(node.requires, id), do: node.id

      cond do
        entry.source == "core" ->
          {:error, "Core plugins can't be uninstalled, only disabled."}

        needed_by != [] ->
          {:error, "#{Enum.join(needed_by, ", ")} need it: uninstall them first."}

        true ->
          :ok
      end
    end
  end

  defp fetch(snapshot, id) do
    case Map.fetch(snapshot.entries, id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, "No plugin #{id} is installed."}
    end
  end

  @doc "Enables `id` and the plugins it needs (see `enable_plan/1`), as `admin`."
  def enable(id, %User{} = admin) do
    with {:ok, ids} <- enable_plan(id) do
      before = Enum.map(active(), & &1.id)
      transition(active(), fn -> Enum.each(ids, &set_enabled(&1, true, id, admin)) end)

      # Plugins suspended while `id` was off are back.
      for target <- Enum.map(active(), & &1.id) -- (ids ++ before) do
        StaffLog.record(admin, "plugin.resume", {"plugin", row_id(target)}, %{
          plugin: target,
          cause: "#{id} was enabled"
        })
      end

      {:ok, ids}
    end
  end

  @doc "Disables `id` and the plugins that need it (see `disable_plan/1`), as `admin`."
  def disable(id, %User{} = admin) do
    with {:ok, ids} <- disable_plan(id) do
      transition(active(), fn -> Enum.each(ids, &set_enabled(&1, false, id, admin)) end)
      {:ok, ids}
    end
  end

  # Turns `target` on or off as part of staff turning `id` on or off.
  defp set_enabled(target, enabled, id, admin) do
    {attrs, action, cause} =
      if enabled do
        Health.reset(target)
        {%{enabled: true, disabled_reason: nil}, "plugin.enable", "needed by #{id}"}
      else
        {%{enabled: false}, "plugin.disable", "needs #{id}"}
      end

    row = save_state(target, attrs)
    details = if target == id, do: %{plugin: target}, else: %{plugin: target, cause: cause}
    StaffLog.record(admin, action, {"plugin", row.id}, details)
  end

  @doc "Uninstalls `id` as `admin`, with its error log (see `uninstall_check/1`)."
  def uninstall(id, %User{} = admin) do
    with :ok <- uninstall_check(id) do
      row = Repo.get_by!(InstalledPlugin, plugin_id: id)

      transition(active(), fn ->
        Repo.delete!(row)
        Health.clear(id)

        StaffLog.record(admin, "plugin.uninstall", {"plugin", row.id}, %{
          plugin: id,
          version: row.version
        })
      end)

      :ok
    end
  end

  @doc """
  Turns off `id`, failing in a row, and tells staff. Plugins that need it
  are suspended until it's enabled again. Logged as the system's doing.
  """
  def trip(id, reason) do
    before = active()

    if Enum.any?(before, &(&1.id == id)) do
      Logger.warning("Plugin #{id} turned off: #{reason}")

      transition(before, fn ->
        row = save_state(id, %{disabled_reason: reason})

        StaffLog.record_system("plugin.auto_disable", {"plugin", row.id}, %{
          plugin: id,
          reason: reason
        })
      end)

      suspended = Enum.map(before, & &1.id) -- [id | Enum.map(active(), & &1.id)]

      for target <- suspended do
        StaffLog.record_system("plugin.suspend", {"plugin", row_id(target)}, %{
          plugin: target,
          cause: "#{id} was turned off"
        })
      end

      notify_admins(id, reason, suspended)
    end

    :ok
  end

  defp notify_admins(id, reason, suspended) do
    body =
      if suspended == [],
        do: reason,
        else: "#{reason}\n\nSuspended until it's enabled again: #{Enum.join(suspended, ", ")}."

    for admin <- admins() do
      Forums.notify(admin, %{
        kind: "plugin_disabled",
        subject: "Plugin #{id} was turned off after failing repeatedly",
        body: body,
        url: FirestormWeb.Web.Endpoint.url() <> "/staff/plugins/" <> id
      })
    end
  end

  defp admins do
    User
    |> join(:inner, [u], r in assoc(u, :roles))
    |> where([u, r], r.name == "admin" and is_nil(u.deleted_at))
    |> Repo.all()
  end

  # Runs `change` in a transaction, then tells every node, and calls the
  # `enabled`/`disabled` hooks of plugins it started or stopped.
  defp transition(before, change) do
    {:ok, _} = Repo.transact(fn -> {:ok, change.()} end)
    changed()

    now = active()
    before_ids = MapSet.new(before, & &1.id)
    now_ids = MapSet.new(now, & &1.id)

    for plugin <- Enum.reverse(before),
        not MapSet.member?(now_ids, plugin.id),
        do: Runner.invoke(plugin, "disabled", [])

    for plugin <- now,
        not MapSet.member?(before_ids, plugin.id),
        do: Runner.invoke(plugin, "enabled", [])

    :ok
  end

  # Saves a plugin's state on its row, creating a core plugin's row.
  defp save_state(id, attrs) do
    row =
      Repo.get_by(InstalledPlugin, plugin_id: id) ||
        core_row(Map.fetch!(entries(), id))

    Repo.insert_or_update!(Ecto.Changeset.change(row, attrs))
  end

  defp core_row(%{source: "core", manifest: manifest}),
    do: %InstalledPlugin{
      plugin_id: manifest.id,
      source: "core",
      version: manifest.version,
      enabled: true
    }

  defp row_id(id) do
    Repo.one(from(p in InstalledPlugin, where: p.plugin_id == ^id, select: p.id))
  end

  ## Settings

  @doc """
  Saves `id`'s settings from form `params` as `admin`: `{:ok, values}` or
  `{:error, errors}` by key.
  """
  def update_settings(id, params, %User{} = admin) do
    snapshot = snapshot()
    {:ok, %{manifest: %Manifest{} = manifest} = entry} = fetch(snapshot, id)
    current = Settings.values(manifest.settings, entry.row && entry.row.settings)

    with {:ok, stored} <- Settings.cast_all(manifest.settings, params) do
      values = Settings.values(manifest.settings, stored)

      changes =
        for {key, value} <- values, value != current[key], into: %{} do
          {key, %{before: current[key], after: value}}
        end

      if changes != %{}, do: save_settings(id, stored, changes, admin)
      {:ok, values}
    end
  end

  defp save_settings(id, stored, changes, admin) do
    {:ok, _} =
      Repo.transact(fn ->
        row = save_state(id, %{settings: stored})
        details = Map.put(changes, :plugin, id)
        {:ok, StaffLog.record(admin, "plugin.settings", {"plugin", row.id}, details)}
      end)

    changed()
  end

  ## Errors

  @doc "Adds to a plugin's error log (see `FirestormWeb.Plugins.Health`)."
  defdelegate log_error(plugin_id, hook, kind, message), to: Health
end
