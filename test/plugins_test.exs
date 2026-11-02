defmodule FirestormWeb.PluginsTest do
  # Not async: some tests set the core plugins, which is global config.
  use FirestormWeb.DataCase

  @moduletag :capture_log

  import FirestormWeb.PluginHelpers

  import FirestormWeb.Web.ConnCase,
    only: [admin_fixture: 0, user_fixture: 0, category_fixture: 1, thread_fixture: 2]

  alias FirestormWeb.{Forums, Plugin, Plugins}
  alias FirestormWeb.Forums.{Notification, StaffAction}
  alias FirestormWeb.Plugin.{Bundle, Host, Runner}
  alias FirestormWeb.Plugins.{Health, InstalledPlugin}
  alias FirestormWeb.Test.{CrashingPlugin, GreeterPlugin}

  setup do
    %{admin: admin_fixture()}
  end

  defp ids, do: Enum.map(Plugins.active(), & &1.id)

  defp logged(action),
    do: Repo.all(from(a in StaffAction, where: a.action == ^action, order_by: a.id))

  defp plugin(id, deps \\ %{}, extra \\ %{}),
    do: Map.merge(%{"id" => id, "name" => id, "dependencies" => deps}, extra)

  describe "install" do
    test "stores the bundle with its checksum, disabled, and logs it", %{admin: admin} do
      id = install_plugin!(admin, %{"permissions" => ["read"]})

      row = Repo.get_by!(InstalledPlugin, plugin_id: id)
      assert %{enabled: false, source: "upload", version: "1.0.0"} = row
      assert row.checksum == Base.encode16(:crypto.hash(:sha256, row.bundle), case: :lower)
      assert ids() == []

      assert [%{actor_id: actor, details: %{"plugin" => ^id, "permissions" => "read"}}] =
               logged("plugin.install")

      assert actor == admin.id
    end

    test "fails naming a missing dependency or an incompatible version", %{admin: admin} do
      {:ok, bundle} = Bundle.read(bundle_zip(plugin("needy", %{"base" => "~> 1.0"})))

      assert {:error, "It needs plugin base ~> 1.0, which isn't installed."} =
               Plugins.install(bundle, admin)

      install_plugin!(admin, plugin("base", %{}, %{"version" => "2.0.0"}))

      assert {:error, "It needs plugin base ~> 1.0, but 2.0.0 is installed."} =
               Plugins.install(bundle, admin)
    end

    test "rejects a cycle, naming it", %{admin: admin} do
      install_plugin!(
        admin,
        plugin("alpha", %{}, %{"optional_dependencies" => %{"beta" => ">= 0.0.0"}})
      )

      {:ok, bundle} = Bundle.read(bundle_zip(plugin("beta", %{"alpha" => ">= 0.0.0"})))

      assert {:error, message} = Plugins.install(bundle, admin)
      assert message =~ "dependency cycle: alpha → beta → alpha"
    end
  end

  describe "upgrade" do
    test "replaces the bundle, keeping state and settings", %{admin: admin} do
      settings = %{"settings" => [%{"key" => "n", "type" => "integer", "default" => 1}]}
      id = install_plugin!(admin, settings, nil, enable: true)
      {:ok, _} = Plugins.update_settings(id, %{"n" => "5"}, admin)

      {:ok, bundle} = Bundle.read(bundle_zip(Map.put(settings, "version", "1.1.0")))
      {:ok, _} = Plugins.install(bundle, admin)

      assert [%Plugin{manifest: %{version: "1.1.0"}, settings: %{"n" => 5}}] = Plugins.active()

      assert [%{details: %{"version" => %{"before" => "1.0.0", "after" => "1.1.0"}}}] =
               logged("plugin.upgrade")
    end

    test "needs a newer version", %{admin: admin} do
      install_plugin!(admin, %{"version" => "1.2.0"})
      {:ok, bundle} = Bundle.read(bundle_zip(%{"version" => "1.1.0"}))
      assert {:error, "Version 1.2.0 is installed" <> _} = Plugins.install(bundle, admin)
    end

    test "is refused when it would break a dependent", %{admin: admin} do
      install_plugin!(admin, plugin("base"))
      install_plugin!(admin, plugin("app", %{"base" => "~> 1.0"}))

      {:ok, bundle} = Bundle.read(bundle_zip(plugin("base", %{}, %{"version" => "2.0.0"})))

      assert {:error, "Plugin app needs plugin base ~> 1.0, but this is 2.0.0."} =
               Plugins.install(bundle, admin)
    end
  end

  describe "enable, disable, uninstall" do
    test "enabling enables what it needs first, logging the cause", %{admin: admin} do
      install_plugin!(admin, plugin("core-lib"))
      install_plugin!(admin, plugin("lib", %{"core-lib" => "~> 1.0"}))
      install_plugin!(admin, plugin("app", %{"lib" => "~> 1.0"}))

      assert {:ok, ["core-lib", "lib", "app"]} = Plugins.enable_plan("app")
      assert {:ok, ["core-lib", "lib", "app"]} = Plugins.enable("app", admin)
      assert ids() == ["core-lib", "lib", "app"]

      assert [
               %{details: %{"plugin" => "core-lib", "cause" => "needed by app"}},
               %{details: %{"plugin" => "lib", "cause" => "needed by app"}},
               %{details: %{"plugin" => "app"} = details}
             ] = logged("plugin.enable")

      refute Map.has_key?(details, "cause")
    end

    test "disabling cascades to the plugins that need it", %{admin: admin} do
      install_plugin!(admin, plugin("base"))
      install_plugin!(admin, plugin("app", %{"base" => "~> 1.0"}))

      install_plugin!(
        admin,
        plugin("extra", %{}, %{"optional_dependencies" => %{"base" => "~> 1.0"}})
      )

      {:ok, _} = Plugins.enable("app", admin)
      {:ok, _} = Plugins.enable("extra", admin)

      assert {:ok, ["base", "app"]} = Plugins.disable_plan("base")
      assert {:ok, ["base", "app"]} = Plugins.disable("base", admin)
      # An optional dependent carries on without it.
      assert ids() == ["extra"]

      assert [_, %{details: %{"plugin" => "app", "cause" => "needs base"}}] =
               logged("plugin.disable")
    end

    test "uninstalling a plugin others need is refused", %{admin: admin} do
      install_plugin!(admin, plugin("base"))
      install_plugin!(admin, plugin("app", %{"base" => "~> 1.0"}))

      assert {:error, "app need it: uninstall them first."} = Plugins.uninstall("base", admin)
      assert :ok = Plugins.uninstall("app", admin)
      assert :ok = Plugins.uninstall("base", admin)
      assert Repo.all(InstalledPlugin) == []
      assert length(logged("plugin.uninstall")) == 2
    end

    test "settings are validated, saved and logged", %{admin: admin} do
      settings = [
        %{"key" => "n", "type" => "integer", "default" => 1, "min" => 0},
        %{"key" => "on", "type" => "boolean", "default" => false}
      ]

      id = install_plugin!(admin, %{"settings" => settings}, nil, enable: true)

      assert {:error, %{"n" => "must be at least 0"}} =
               Plugins.update_settings(id, %{"n" => "-1"}, admin)

      assert {:ok, %{"n" => 3, "on" => true}} =
               Plugins.update_settings(id, %{"n" => "3", "on" => "true"}, admin)

      assert [%Plugin{settings: %{"n" => 3, "on" => true}}] = Plugins.active()
      assert [%{details: %{"n" => %{"before" => 1, "after" => 3}}}] = logged("plugin.settings")
    end
  end

  describe "hooks" do
    test "run in the sandbox; a lifecycle hook that throws is logged", %{admin: admin} do
      id =
        install_plugin!(admin, %{"hooks" => ["enabled"]}, %{
          "index.js" => "exports.enabled = () => { throw new Error('no setup') }"
        })

      {:ok, _} = Plugins.enable(id, admin)

      assert [%{hook: "enabled", kind: "js_error", message: "no setup" <> _}] = Health.errors(id)
      assert %{calls: 1, failures: 1} = Health.stats(id)
    end

    test "are only called when declared", %{admin: admin} do
      id =
        install_plugin!(admin, %{}, %{"index.js" => "exports.enabled = () => { throw 1 }"},
          enable: true
        )

      assert {:error, :not_implemented} = Runner.invoke(Plugins.get_active(id), "enabled", [])
      assert Health.errors(id) == []
    end
  end

  describe "permissions" do
    setup %{admin: admin} do
      thread = thread_fixture(category_fixture("Public"), user_fixture())
      %{thread: thread, admin: admin}
    end

    test "deny by default, and the denial is logged", %{admin: admin, thread: thread} do
      source = "exports.read = (args) => firefly.call('threads.get', {id: args.id}).title;"

      id =
        install_plugin!(admin, %{"exports" => ["read"]}, %{"index.js" => source}, enable: true)

      assert {:error, {:js_error, message}} =
               Runner.invoke(Plugins.get_active(id), "call_export", ["read", %{"id" => thread.id}])

      assert message =~ ~s(permission denied: threads.get needs the "read" permission)
      assert [_js_error, %{kind: "denied", hook: "threads.get"}] = Health.errors(id)
    end

    test "with the permission, reads see only what anonymous visitors may", %{
      admin: admin,
      thread: thread
    } do
      plugin = %Plugin{
        id: "reader",
        module: Plugin.Sandboxed,
        manifest: %Plugin.Manifest{
          id: "reader",
          name: "R",
          version: "1.0.0",
          firefly: "~> 1.0",
          permissions: ["read"]
        }
      }

      assert {:ok, %{title: "OTP is cool"}} =
               Host.call(plugin, "threads.get", %{"id" => thread.id})

      {:ok, role} = Forums.create_role("staff")
      {:ok, private} = Forums.create_category(%{title: "Staff", role_ids: [role.id]})
      hidden = thread_fixture(private, admin)

      assert {:error, "not found"} = Host.call(plugin, "threads.get", %{"id" => hidden.id})
      [post] = Repo.preload(hidden, :posts).posts
      assert {:error, "not found"} = Host.call(plugin, "posts.get", %{"id" => post.id})
      assert {:error, "unknown function fs.read"} = Host.call(plugin, "fs.read", %{})
    end
  end

  describe "circuit breaker" do
    test "turns a failing plugin off, suspends its dependents and tells staff", %{admin: admin} do
      install_plugin!(admin, plugin("flaky", %{}, %{"exports" => ["go"]}), %{
        "index.js" => "exports.go = () => { throw new Error('flaky') }"
      })

      install_plugin!(admin, plugin("app", %{"flaky" => "~> 1.0"}))
      {:ok, _} = Plugins.enable("app", admin)
      flaky = Plugins.get_active("flaky")

      for _ <- 1..5, do: Runner.invoke(flaky, "call_export", ["go", nil])

      assert ids() == []
      assert %{status: {:auto_disabled, "5 failures in a row" <> _}} = Plugins.describe("flaky")
      assert %{status: {:suspended, ["flaky"]}} = Plugins.describe("app")

      assert [%{actor_id: nil, details: %{"plugin" => "flaky"}}] = logged("plugin.auto_disable")

      assert [%{actor_id: nil, details: %{"plugin" => "app", "cause" => "flaky was turned off"}}] =
               logged("plugin.suspend")

      assert [%Notification{kind: "plugin_disabled", body: body}] =
               Repo.all(from(n in Notification, where: n.user_id == ^admin.id))

      assert body =~ "Suspended until it's enabled again: app"

      # Enabling it again resumes its dependents.
      {:ok, ["flaky"]} = Plugins.enable("flaky", admin)
      assert ids() == ["flaky", "app"]

      assert [%{details: %{"plugin" => "app", "cause" => "flaky was enabled"}}] =
               logged("plugin.resume")
    end

    test "a success resets the count", %{admin: admin} do
      install_plugin!(
        admin,
        %{"exports" => ["go"]},
        %{"index.js" => "exports.go = (fail) => { if (fail) throw 1 }"},
        enable: true
      )

      plugin = Plugins.get_active("test-plugin")

      for _ <- 1..4, do: Runner.invoke(plugin, "call_export", ["go", true])
      Runner.invoke(plugin, "call_export", ["go", false])
      for _ <- 1..4, do: Runner.invoke(plugin, "call_export", ["go", true])

      assert ids() == ["test-plugin"]
    end
  end

  describe "core plugins" do
    test "load from config, enabled, and can be disabled", %{admin: admin} do
      with_core_plugins([GreeterPlugin], fn ->
        assert [%Plugin{id: "greeter", module: GreeterPlugin, source: "core"} = greeter] =
                 Plugins.active()

        assert greeter.manifest.exports == ["greet"]

        assert {:ok, "Hello, Ann"} =
                 Runner.invoke(greeter, "call_export", ["greet", %{"name" => "Ann"}])

        assert {:error, "name is required"} =
                 Runner.invoke(greeter, "call_export", ["greet", %{}])

        {:ok, _} = Plugins.update_settings("greeter", %{"greeting" => "Hi"}, admin)

        assert {:ok, "Hi, Ann"} =
                 Runner.invoke(Plugins.get_active("greeter"), "call_export", [
                   "greet",
                   %{"name" => "Ann"}
                 ])

        assert {:ok, ["greeter"]} = Plugins.disable("greeter", admin)
        assert Plugins.active() == []

        assert {:error, "Core plugins can't be uninstalled, only disabled."} =
                 Plugins.uninstall_check("greeter")
      end)
    end

    test "a core plugin calls an uploaded one it depends on", %{admin: admin} do
      install_plugin!(
        admin,
        plugin("loud", %{}, %{"exports" => ["shout"]}),
        %{
          "index.js" => "exports.shout = (text) => text.toUpperCase() + '!'"
        },
        enable: true
      )

      with_core_plugins([GreeterPlugin], fn ->
        assert ids() == ["loud", "greeter"]
        greeter = Plugins.get_active("greeter")

        assert {:ok, "HELLO, ANN!"} =
                 Runner.invoke(greeter, "call_export", ["greet", %{"name" => "Ann"}])
      end)
    end

    test "an uploaded plugin calls a core one it depends on, and only its exports", %{
      admin: admin
    } do
      with_core_plugins([GreeterPlugin], fn ->
        source = """
        exports.welcome = (name) => firefly.call('plugins.call', {plugin: 'greeter', function: 'greet', args: {name}});
        exports.sneak = () => firefly.call('plugins.call', {plugin: 'greeter', function: 'enabled', args: null});
        """

        install_plugin!(
          admin,
          plugin("welcome", %{"greeter" => "~> 1.0"}, %{"exports" => ["welcome", "sneak"]}),
          %{
            "index.js" => source
          },
          enable: true
        )

        assert ids() == ["greeter", "welcome"]
        welcome = Plugins.get_active("welcome")
        assert {:ok, "Hello, Bo"} = Runner.invoke(welcome, "call_export", ["welcome", "Bo"])

        assert {:error, {:js_error, message}} =
                 Runner.invoke(welcome, "call_export", ["sneak", nil])

        assert message =~ "plugin greeter doesn't export enabled"
      end)
    end

    test "a plugin can't call one it doesn't depend on", %{admin: admin} do
      with_core_plugins([GreeterPlugin], fn ->
        id =
          install_plugin!(
            admin,
            %{"exports" => ["go"]},
            %{
              "index.js" =>
                "exports.go = () => firefly.call('plugins.call', {plugin: 'greeter', function: 'greet', args: {name: 'x'}})"
            },
            enable: true
          )

        assert {:error, {:js_error, message}} =
                 Runner.invoke(Plugins.get_active(id), "call_export", ["go", nil])

        assert message =~ "test-plugin doesn't depend on greeter"
      end)
    end

    test "a core plugin needing a missing uploaded one stays inactive; a crash is contained", %{
      admin: admin
    } do
      with_core_plugins([CrashingPlugin], fn ->
        assert %{status: :broken, problems: ["needs plugin base ~> 1.0, which isn't installed"]} =
                 Plugins.describe("crashing")

        install_plugin!(admin, plugin("base"), nil, enable: true)
        assert ids() == ["base", "crashing"]

        assert {:error, {:crash, message}} =
                 Runner.invoke(Plugins.get_active("crashing"), "call_export", ["boom", nil])

        assert message =~ "boom"
        # Uploading over a core plugin's id is refused.
        {:ok, bundle} = Bundle.read(bundle_zip(plugin("crashing", %{}, %{"version" => "9.0.0"})))
        assert {:error, "crashing is a core plugin" <> _} = Plugins.install(bundle, admin)
      end)
    end
  end

  test "a runaway plugin is stopped and the caller carries on", %{admin: admin} do
    id =
      install_plugin!(
        admin,
        %{"exports" => ["spin"]},
        %{"index.js" => "exports.spin = () => { for (;;) {} }"},
        enable: true
      )

    assert {:error, {:timeout, _}} =
             Runner.invoke(Plugins.get_active(id), "call_export", ["spin", nil])

    assert [%{kind: "timeout"}] = Health.errors(id)
  end

  test "the cache reloads when another node announces a change", %{admin: admin} do
    id = install_plugin!(admin, %{}, nil, enable: true)
    Application.put_env(:firestorm_web, :plugins_cache, true)
    Plugins.clear_cache()

    try do
      assert ids() == [id]
      Repo.update_all(InstalledPlugin, set: [enabled: false])
      assert ids() == [id]

      # As another node's change would: the registry hears it and reloads.
      Phoenix.PubSub.broadcast(FirestormWeb.PubSub, Plugins.topic(), :plugins_changed)
      :sys.get_state(FirestormWeb.Plugins.Registry)
      assert ids() == []
    after
      Application.put_env(:firestorm_web, :plugins_cache, false)
    end
  end
end
