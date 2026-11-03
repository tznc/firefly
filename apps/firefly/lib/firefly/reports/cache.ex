defmodule Firefly.Reports.Cache do
  @moduledoc """
  Reports' results for the day (see `Firefly.Reports`), in an ETS table
  this process owns. An entry is keyed by the day it was computed on, so
  it's stale the next day; stale entries are dropped as new ones are
  stored. Off with `config :firefly, Firefly.Reports, cache: false` (tests,
  where each test has its own data).
  """
  use GenServer

  @table __MODULE__

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The cached value for `key` today, or `fun`'s, stored:
  `%{result: value, computed_at: datetime}`.
  """
  def fetch(key, fun) do
    today = Date.utc_today()

    case enabled?() && :ets.lookup(@table, {today, key}) do
      [{_key, entry}] ->
        entry

      _missing ->
        entry = %{result: fun.(), computed_at: DateTime.utc_now(:second)}

        if enabled?() do
          :ets.select_delete(@table, [
            {{{:"$1", :_}, :_}, [{:"=/=", :"$1", {:const, today}}], [true]}
          ])

          :ets.insert(@table, {{today, key}, entry})
        end

        entry
    end
  end

  @doc "Drops today's entry for `key`."
  def delete(key) do
    if enabled?(), do: :ets.delete(@table, {Date.utc_today(), key})
    :ok
  end

  defp enabled?,
    do: Application.get_env(:firefly, Firefly.Reports, [])[:cache] != false and table?()

  defp table?, do: :ets.whereis(@table) != :undefined

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end
end
