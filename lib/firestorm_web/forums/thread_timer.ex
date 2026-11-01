defmodule FirestormWeb.Forums.ThreadTimer do
  @moduledoc """
  A thread's pending timer: at `run_at`, `action` (`"close"`, `"open"` or
  `"delete"`) is done to the thread as `created_by`. A thread has at most
  one; see `FirestormWeb.TopicTimers`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FirestormWeb.Forums.{Thread, User}

  @actions ~w(close open delete)

  def actions, do: @actions

  schema "forums_thread_timers" do
    field(:action, :string)
    field(:run_at, :utc_datetime)
    belongs_to(:thread, Thread)
    belongs_to(:created_by, User)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = timer, attrs) do
    timer
    |> cast(attrs, [:action, :run_at])
    |> validate_required([:action, :run_at])
    |> validate_inclusion(:action, @actions)
  end

  @doc "What the timer will do, for people: \"close\" becomes \"Closes\"."
  def label(%__MODULE__{action: "close"}), do: "Closes"
  def label(%__MODULE__{action: "open"}), do: "Reopens"
  def label(%__MODULE__{action: "delete"}), do: "Will be deleted"
end
