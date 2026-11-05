defmodule Firefly.Security.Jail.Tables do
  @moduledoc """
  Owns the jail's two ETS tables on this node (see `Firefly.Security.Jail`):

    * `#{inspect(__MODULE__)}.Counters` - signal points per
      `{jail, address key, time bucket}`, bumped atomically by the processes
      that report them (`:ets.update_counter/4`), so a busy jail needs no
      process of its own;
    * `#{inspect(__MODULE__)}.Bans` - the bans in force, `{key, until_ms |
      :infinity, jail, range}`, read on every request.

  It keeps the ban cache in step with the rest of the cluster: every ban and
  unban is broadcast on `Firefly.PubSub` (`topic/0`) and applied here, and
  the bans in force are loaded from the database at start (`Jail.reload/0`
  does it again). Every minute it drops counters older than any window and
  bans that have ended.

  Multi-tenancy: the keys and the topic get a tenant prefix (a tenant's
  tree runs its own process), as for `Firefly.RateLimit`.
  """

  use GenServer
  require Logger

  @counters Module.concat(__MODULE__, Counters)
  @bans Module.concat(__MODULE__, Bans)
  @topic "security:bans"
  @prune_every :timer.minutes(1)
  # Counters older than this are no use to any window (findtime's max).
  @keep_ms :timer.hours(24)

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "The counters table."
  def counters, do: @counters

  @doc "The ban cache."
  def bans, do: @bans

  @doc "The PubSub topic bans and unbans are broadcast on."
  def topic, do: @topic

  @impl true
  def init(_opts) do
    :ets.new(@counters, [:named_table, :public, :set, write_concurrency: true])
    :ets.new(@bans, [:named_table, :public, :set, read_concurrency: true])
    Phoenix.PubSub.subscribe(Firefly.PubSub, @topic)
    Process.send_after(self(), :prune, @prune_every)
    {:ok, %{}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    # Not in tests (the database belongs to each test there), nor while the
    # jail is off.
    if Firefly.Security.Jail.configured?() do
      try do
        Firefly.Security.Jail.reload()
      rescue
        error -> Logger.error("Loading IP bans failed: #{Exception.message(error)}")
      end
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:jail_ban, entry}, state) do
    :ets.insert(@bans, entry)
    {:noreply, state}
  end

  def handle_info({:jail_unban, key}, state) do
    :ets.delete(@bans, key)
    {:noreply, state}
  end

  def handle_info(:prune, state) do
    prune(System.system_time(:millisecond))
    Process.send_after(self(), :prune, @prune_every)
    {:noreply, state}
  end

  @doc false
  def prune(now_ms) do
    :ets.select_delete(@counters, [
      {{{:_, :_, :"$1", :"$2"}, :_}, [{:<, {:*, :"$1", :"$2"}, now_ms - @keep_ms}], [true]}
    ])

    :ets.select_delete(@bans, [
      {{:_, :"$1", :_, :_}, [{:is_integer, :"$1"}, {:"=<", :"$1", now_ms}], [true]}
    ])
  end
end
