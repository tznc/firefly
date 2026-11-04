defmodule Firefly.ClusterNodesTest do
  @moduledoc """
  Two real nodes finding each other through the test database: this VM,
  made a distributed node for the test, and a peer started with `:peer`,
  each running `Firefly.Cluster.Discovery` on a channel of their own.

  Tagged `:cluster` and left out of a plain `mix test` (it needs `epmd`,
  which it starts, and turns this VM into a node for its duration); CI
  runs it. Locally: `cd apps/firefly && mix test --only cluster`.
  """
  # Not async: it makes this VM a distributed node for its duration.
  use ExUnit.Case, async: false

  @moduletag :cluster
  @moduletag :capture_log

  alias Firefly.Cluster

  @generation {Firefly.SiteSettings, :generation}

  setup do
    {_output, 0} = System.cmd(System.find_executable("epmd"), ["-daemon"])
    {:ok, _pid} = Node.start(:"firefly_test@127.0.0.1", name_domain: :longnames)
    Node.set_cookie(:"firefly-cluster-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> Node.stop() end)

    # A channel no other test run listens on, and quick heartbeats.
    Application.put_env(:firefly, Cluster,
      strategy: :postgres,
      channel: "firefly_cluster_test_#{System.unique_integer([:positive])}",
      heartbeat_interval: 200
    )

    on_exit(fn -> Application.delete_env(:firefly, Cluster) end)

    test = self()

    :telemetry.attach(
      "cluster-nodes-test",
      [:firefly, :cluster, :node],
      fn _event, measurements, metadata, _config ->
        send(test, {:cluster, metadata.event, metadata.node, measurements.connected})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("cluster-nodes-test") end)
    :ok
  end

  test "nodes connect through Postgres, and PubSub broadcasts (cache invalidation) cross" do
    start_supervised!(Cluster.Monitor)
    start_supervised!(Cluster.Discovery)
    {peer, peer_node} = start_peer()

    assert_receive {:cluster, :up, ^peer_node, 1}, 15_000
    assert Cluster.status() == %{enabled: true, nodes: 1}

    # Site settings changed on the peer clear this node's cached ones (a new
    # cache generation, see Firefly.SiteSettings.clear_cache/0)...
    topic = Firefly.SiteSettings.topic()
    generation = :persistent_term.get(@generation, nil)

    eventually(fn ->
      :erpc.call(peer_node, Phoenix.PubSub, :broadcast, [
        Firefly.PubSub,
        topic,
        :site_settings_changed
      ])

      Process.sleep(200)
      assert :persistent_term.get(@generation, nil) != generation
    end)

    # ...and this node's broadcasts reach the peer's.
    eval(peer_node, """
    spawn(fn ->
      Phoenix.PubSub.subscribe(Firefly.PubSub, topic)
      send(test, :subscribed)

      receive do
        message -> send(test, {:on_peer, message})
      end
    end)
    """)

    assert_receive :subscribed, 5_000

    eventually(fn ->
      Phoenix.PubSub.broadcast(Firefly.PubSub, topic, :site_settings_changed)
      assert_receive {:on_peer, :site_settings_changed}, 200
    end)

    :peer.stop(peer)
    assert_receive {:cluster, :down, ^peer_node, 0}, 5_000
  end

  # A peer node with this VM's code and the domain's config, running PubSub
  # and cluster discovery as the domain's supervision tree does.
  defp start_peer do
    {:ok, peer, peer_node} =
      :peer.start_link(%{
        name: :"firefly_peer_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [
          ~c"-setcookie",
          Atom.to_charlist(Node.get_cookie()),
          ~c"-kernel",
          ~c"logger_level",
          ~c"warning"
        ]
      })

    :ok = :erpc.call(peer_node, :code, :add_paths, [:code.get_path()])

    :ok =
      :erpc.call(peer_node, Application, :put_all_env, [
        [firefly: Application.get_all_env(:firefly)]
      ])

    {:ok, _apps} =
      :erpc.call(peer_node, Application, :ensure_all_started, [
        [:postgrex, :libcluster, :phoenix_pubsub]
      ])

    eval(peer_node, """
    {:ok, pid} =
      Supervisor.start_link(
        [{Phoenix.PubSub, name: Firefly.PubSub}, Firefly.Cluster.Discovery],
        strategy: :one_for_one
      )

    # Outlives the call that started it.
    Process.unlink(pid)
    """)

    {peer, peer_node}
  end

  # Runs `code` on the peer, which has the domain's modules but not this
  # test's, with `test` (this process) and `topic` bound.
  defp eval(node, code) do
    binding = [test: self(), topic: Firefly.SiteSettings.topic()]
    :erpc.call(node, Code, :eval_string, [code, binding])
  end

  # Process groups sync shortly after nodes connect: until then a
  # broadcast may not reach the other node yet.
  defp eventually(fun, attempts \\ 25) do
    fun.()
  rescue
    error in ExUnit.AssertionError ->
      if attempts > 1, do: eventually(fun, attempts - 1), else: reraise(error, __STACKTRACE__)
  end
end
