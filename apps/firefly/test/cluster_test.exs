defmodule Firefly.ClusterTest do
  # Not async: these change environment variables and the cluster config.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Firefly.Cluster

  @runtime Path.expand("../../../config/runtime.exs", __DIR__)

  # Every variable the cluster config reads, unset unless a test sets it.
  @unset %{
    "FIREFLY_CLUSTER" => nil,
    "FIREFLY_CLUSTER_NAME" => nil,
    "FIREFLY_CLUSTER_HEARTBEAT_MS" => nil,
    "RELEASE_COOKIE" => nil,
    "RELEASE_ROOT" => nil
  }

  # What production also requires.
  @prod %{
    "FIREFLY_DATABASE_URL" => "ecto://u:p@db/firefly",
    "FIREFLY_SECRET_KEY_BASE" => String.duplicate("k", 64),
    "FIREFLY_VAULT_KEY" => Base.encode64(String.duplicate("v", 32)),
    # Production won't boot without outbound email (see Firefly.MailConfigTest).
    "FIREFLY_MAIL_ADAPTER" => "local"
  }

  @cookie String.duplicate("c", 32)

  setup do
    on_exit(fn -> Application.delete_env(:firefly, Cluster) end)
  end

  # `config/runtime.exs`'s cluster config, read with `vars` in the environment.
  defp cluster_config(vars, env \\ :test) do
    vars = Map.merge(@unset, vars)
    saved = Map.new(vars, fn {name, _} -> {name, System.get_env(name)} end)

    try do
      put_env(vars)
      Config.Reader.read!(@runtime, env: env)[:firefly][Cluster]
    after
      put_env(saved)
    end
  end

  defp put_env(vars) do
    Enum.each(vars, fn
      {name, nil} -> System.delete_env(name)
      {name, value} -> System.put_env(name, value)
    end)
  end

  describe "configuration" do
    test "is off by default and when set to none" do
      assert cluster_config(%{}) == nil
      assert cluster_config(%{"FIREFLY_CLUSTER" => "none"}) == nil

      refute Cluster.enabled?()
      assert Cluster.child_specs() == []
      assert Cluster.status() == %{enabled: false, nodes: 0}
    end

    test "FIREFLY_CLUSTER=postgres turns it on, on its own channel" do
      assert cluster_config(%{"FIREFLY_CLUSTER" => "postgres"}) == [
               strategy: :postgres,
               channel: "firefly_cluster",
               heartbeat_interval: 5_000
             ]

      config =
        cluster_config(%{
          "FIREFLY_CLUSTER" => "postgres",
          "FIREFLY_CLUSTER_NAME" => "staging_2",
          "FIREFLY_CLUSTER_HEARTBEAT_MS" => "1000"
        })

      assert config[:channel] == "firefly_cluster_staging_2"
      assert config[:heartbeat_interval] == 1_000

      Application.put_env(:firefly, Cluster, config)
      assert Cluster.enabled?()
      assert Cluster.child_specs() == [Cluster.Monitor, Cluster.Discovery]
    end

    test "rejects other strategies and channel names that need quoting" do
      assert_raise RuntimeError, ~r/must be postgres/, fn ->
        cluster_config(%{"FIREFLY_CLUSTER" => "gossip"})
      end

      for name <- ["Staging", "a-b", "x\"; DROP", String.duplicate("a", 41)] do
        assert_raise RuntimeError, ~r/FIREFLY_CLUSTER_NAME/, fn ->
          cluster_config(%{"FIREFLY_CLUSTER" => "postgres", "FIREFLY_CLUSTER_NAME" => name})
        end
      end
    end

    test "production refuses to cluster without a cookie of its own" do
      on = Map.put(@prod, "FIREFLY_CLUSTER", "postgres")

      # Missing (the release's built-in one), or too short.
      for cookie <- [nil, "", "short"] do
        assert_raise RuntimeError, ~r/RELEASE_COOKIE/, fn ->
          cluster_config(Map.put(on, "RELEASE_COOKIE", cookie), :prod)
        end
      end

      # The release's built-in one, given explicitly.
      root = Path.join(System.tmp_dir!(), "firefly-cluster-test-#{System.unique_integer()}")
      File.mkdir_p!(Path.join(root, "releases"))
      File.write!(Path.join(root, "releases/COOKIE"), @cookie)
      on_exit(fn -> File.rm_rf!(root) end)

      assert_raise RuntimeError, ~r/RELEASE_COOKIE/, fn ->
        cluster_config(
          Map.merge(on, %{"RELEASE_COOKIE" => @cookie, "RELEASE_ROOT" => root}),
          :prod
        )
      end

      own = String.duplicate("o", 32)

      assert cluster_config(
               Map.merge(on, %{"RELEASE_COOKIE" => own, "RELEASE_ROOT" => root}),
               :prod
             )[
               :strategy
             ] == :postgres

      # Off, the cookie doesn't matter.
      assert cluster_config(@prod, :prod) == nil
    end
  end

  describe "topologies" do
    test "connect with the repo's settings" do
      Application.put_env(:firefly, Cluster,
        strategy: :postgres,
        channel: "firefly_cluster_x",
        heartbeat_interval: 1_000
      )

      repo = Firefly.Repo.config()

      assert [firefly: [strategy: LibclusterPostgres.Strategy, config: config]] =
               Cluster.topologies()

      for key <- [:hostname, :port, :username, :password, :database],
          do: assert(config[key] == repo[key])

      assert config[:channel_name] == "firefly_cluster_x"
      assert config[:heartbeat_interval] == 1_000
      # Only connection settings: not the pool.
      refute Keyword.has_key?(config, :pool)
    end

    test "keep TLS and socket settings, from a URL too" do
      repo_config =
        Ecto.Repo.Supervisor.parse_url("ecto://user:pass@db.internal:6543/forum") ++
          [ssl: true, socket_options: [:inet6], pool_size: 10]

      [firefly: [strategy: _, config: config]] = Cluster.topologies(repo_config)

      assert config[:hostname] == "db.internal"
      assert config[:port] == 6543
      assert config[:username] == "user"
      assert config[:password] == "pass"
      assert config[:database] == "forum"
      assert config[:ssl] == true
      assert config[:socket_options] == [:inet6]
      refute Keyword.has_key?(config, :pool_size)
      assert config[:channel_name] == "firefly_cluster"
      assert config[:heartbeat_interval] == 5_000
    end
  end

  test "discovery outlives a database it can't reach, retrying" do
    topologies = fn ->
      repo = Keyword.put(Firefly.Repo.config(), :port, 1)
      Cluster.topologies(repo)
    end

    log =
      capture_log(fn ->
        pid = start_supervised!({Cluster.Discovery, topologies: topologies})
        # libcluster's supervisor gives up within milliseconds; discovery
        # waits a second before starting it again.
        Process.sleep(1_500)
        assert Process.alive?(pid)
      end)

    assert log =~ "Cluster discovery stopped"
    assert log =~ "restarting in 1000ms"
    refute log =~ "password"
  end
end
