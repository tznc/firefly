defmodule FirestormWeb.TopicTimers do
  @moduledoc """
  Thread timers: an admin (the `:moderate_thread` policy) sets a thread to
  close, reopen or be deleted at a given time. A thread has at most one
  timer; setting another replaces it.

  Timers live in the database (`FirestormWeb.Forums.ThreadTimer`), so they
  survive restarts: `FirestormWeb.TopicTimers.Scheduler` runs the due ones
  every so often, including any that fell due while the app was down.
  Running one is idempotent and safe across nodes: the timer row is locked
  (`SKIP LOCKED`, so two nodes never take the same one) and deleted in the
  same transaction as the action, and an action that's already done (a
  closed thread set to close) does nothing. The action is taken as the
  admin who set the timer, so the staff log shows who scheduled it.
  """

  import Ecto.Query
  require Logger

  alias FirestormWeb.{Forums, Repo, StaffLog}
  alias FirestormWeb.Forums.{Thread, ThreadTimer, User}

  @doc "The thread's pending timer, or nil."
  def get_timer(%Thread{id: thread_id}), do: Repo.get_by(ThreadTimer, thread_id: thread_id)

  @doc "A changeset for the timer form."
  def change_timer(attrs \\ %{}), do: ThreadTimer.changeset(%ThreadTimer{}, attrs)

  @doc """
  Sets `thread`'s timer as `actor`: `action` (`"close"`, `"open"` or
  `"delete"`) at `run_at` (a `DateTime` in the future).
  """
  def set_timer(%Thread{} = thread, attrs, %User{} = actor) do
    changeset =
      %ThreadTimer{thread_id: thread.id, created_by_id: actor.id}
      |> ThreadTimer.changeset(attrs)
      |> Ecto.Changeset.validate_change(:run_at, fn :run_at, at ->
        if DateTime.after?(at, DateTime.utc_now()),
          do: [],
          else: [run_at: "must be in the future"]
      end)

    result =
      Repo.transact(fn ->
        with {:ok, timer} <-
               Repo.insert(changeset,
                 on_conflict: {:replace, [:action, :run_at, :created_by_id, :updated_at]},
                 conflict_target: :thread_id,
                 returning: true
               ) do
          StaffLog.record(actor, "thread.timer", thread, %{
            title: thread.title,
            action: timer.action,
            at: timer.run_at
          })

          {:ok, timer}
        end
      end)

    with {:ok, timer} <- result do
      Forums.thread_changed(:thread_updated, thread)
      {:ok, timer}
    end
  end

  @doc "Cancels `thread`'s timer, if it has one, as `actor`."
  def cancel_timer(%Thread{} = thread, %User{} = actor) do
    {:ok, cancelled} =
      Repo.transact(fn ->
        case Repo.delete_all(where(ThreadTimer, thread_id: ^thread.id)) do
          {0, _} ->
            {:ok, false}

          _deleted ->
            StaffLog.record(actor, "thread.timer_cancel", thread, %{title: thread.title})
            {:ok, true}
        end
      end)

    if cancelled, do: Forums.thread_changed(:thread_updated, thread)
    :ok
  end

  @doc """
  Runs every timer due at `now`, one transaction each. Returns how many ran.
  """
  def run_due(now \\ DateTime.utc_now()), do: run_due(now, 0)

  defp run_due(now, count) do
    case run_next(now) do
      {:ok, :none} ->
        count

      {:ok, announce} ->
        announce.()
        run_due(now, count + 1)
    end
  end

  defp run_next(now) do
    Repo.transact(fn ->
      ThreadTimer
      |> where([t], t.run_at <= ^now)
      |> order_by([t], asc: t.run_at, asc: t.id)
      |> limit(1)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> Repo.one()
      |> case do
        nil ->
          {:ok, :none}

        timer ->
          timer = Repo.preload(timer, [:thread, :created_by])
          Repo.delete!(timer)
          {:ok, run(timer)}
      end
    end)
  end

  # Does the timer's action unless it's already done. Returns what to
  # announce once the transaction commits.
  defp run(%ThreadTimer{action: action, thread: thread, created_by: actor}) do
    details = %{timer: true}

    result =
      case action do
        "close" when is_nil(thread.closed_at) ->
          Forums.close_thread_unannounced(thread, true, actor, details)

        "open" when not is_nil(thread.closed_at) ->
          Forums.close_thread_unannounced(thread, false, actor, details)

        "delete" ->
          Forums.delete_thread_unannounced(thread, actor)

        _already_done ->
          {:ok, thread, fn -> :ok end}
      end

    case result do
      {:ok, _thread, announce} ->
        announce

      {:error, reason} ->
        # Dropped rather than retried forever: it would fail the same way.
        Logger.error("Thread timer #{action} on thread #{thread.id} failed: #{inspect(reason)}")
        fn -> :ok end
    end
  end

  defmodule Scheduler do
    @moduledoc """
    Runs what's due, from the database: thread timers (see
    `FirestormWeb.TopicTimers`), bookmark reminders (see
    `FirestormWeb.Bookmarks`), polls' closing times (see
    `FirestormWeb.Polls`), unused uploads' removal (see
    `FirestormWeb.Uploads`) and unseen link previews' (see
    `FirestormWeb.LinkPreviews`). At start (so nothing that fell due while the
    app was down is lost), then every `:interval` milliseconds (the
    `FirestormWeb.TopicTimers` config; 30 seconds by default), so each runs
    at most that late. Every job takes its due rows one locked transaction
    at a time, so each runs once, even with several nodes.
    """
    use GenServer
    require Logger

    # Each has `run_due/0`.
    @jobs [
      FirestormWeb.TopicTimers,
      FirestormWeb.Bookmarks,
      FirestormWeb.Polls,
      FirestormWeb.Uploads,
      FirestormWeb.LinkPreviews
    ]

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(opts) do
      interval =
        opts[:interval] ||
          Application.get_env(:firestorm_web, FirestormWeb.TopicTimers, [])[:interval] || 30_000

      send(self(), :tick)
      {:ok, %{interval: interval}}
    end

    @impl true
    def handle_info(:tick, state) do
      # A failing job is logged, not fatal: crashing would only retry it
      # straight away, and then take the app down with it. Nor does it hold
      # up the other jobs.
      for job <- @jobs do
        try do
          job.run_due()
        rescue
          error -> Logger.error("#{inspect(job)} failed: " <> Exception.message(error))
        end
      end

      Process.send_after(self(), :tick, state.interval)
      {:noreply, state}
    end
  end
end
