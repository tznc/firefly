defmodule FirestormWeb.Penalties do
  @moduledoc """
  Time-boxed penalties admins put on members, with a reason:

    * silence - the user can log in and read, but not post, start threads,
      message or like (enforced by `FirestormWeb.Posting`).
    * suspend - the user can't log in: sessions and API tokens resolve to
      nobody while it lasts, and open pages are disconnected.

  A penalty is in force while its end date is in the future
  (`User.silenced?/1`, `User.suspended?/1`), so it lapses on its own; no job
  is needed. Admins can't be penalized. Each penalty and lift goes to the
  staff log, and the user is told by email and in-app notification.
  """

  require Logger

  alias FirestormWeb.{Emails, Forums, Mailer, Repo, StaffLog}
  alias FirestormWeb.Forums.User
  alias FirestormWeb.Web.{Paths, Session}

  # "Forever" is an end date nobody will reach, so one comparison covers it.
  @forever ~U[9999-12-31 23:59:59Z]

  @fields %{
    silence: {:silenced_until, :silence_reason},
    suspend: {:suspended_until, :suspend_reason}
  }

  @doc "The durations admins pick from, as select options."
  def durations do
    [
      {"1 day", "1d"},
      {"1 week", "1w"},
      {"1 month", "1m"},
      {"Until a date", "date"},
      {"Forever", "forever"}
    ]
  end

  @doc """
  Silences or suspends (`kind`) `user` as `admin`. `params` (string keys):
  `"duration"` (see `durations/0`), `"until"` (an ISO date, for `"date"`) and
  `"reason"` (required).
  """
  def penalize(kind, %User{} = user, %User{} = admin, params) when is_map_key(@fields, kind) do
    with :ok <- penalizable(user),
         {:ok, until} <- ends_at(params["duration"], params["until"]),
         {:ok, reason} <- reason(params["reason"]) do
      {until_field, reason_field} = @fields[kind]

      {:ok, user} =
        Repo.transact(fn ->
          {:ok, user} =
            user
            |> Ecto.Changeset.change([{until_field, until}, {reason_field, reason}])
            |> Repo.update()

          StaffLog.record(admin, "user.#{kind}", user, %{
            username: user.username,
            reason: reason,
            ends: ends_text(until)
          })

          {:ok, user}
        end)

      # Enforced first: telling the user can fail (email), the penalty can't.
      reload_pages(user)
      tell(kind, user, until, reason)
      {:ok, user}
    end
  end

  @doc "Lifts `user`'s silence or suspension (`kind`) as `admin`."
  def lift(kind, %User{} = user, %User{} = admin) when is_map_key(@fields, kind) do
    {until_field, reason_field} = @fields[kind]
    action = if kind == :silence, do: "user.unsilence", else: "user.unsuspend"

    {:ok, user} =
      Repo.transact(fn ->
        {:ok, user} =
          user
          |> Ecto.Changeset.change([{until_field, nil}, {reason_field, nil}])
          |> Repo.update()

        StaffLog.record(admin, action, user, %{username: user.username})
        {:ok, user}
      end)

    reload_pages(user)
    {:ok, user}
  end

  defp penalizable(user), do: if(Forums.admin?(user), do: {:error, :admin}, else: :ok)

  defp ends_at("1d", _date), do: {:ok, from_now(1)}
  defp ends_at("1w", _date), do: {:ok, from_now(7)}
  defp ends_at("1m", _date), do: {:ok, from_now(30)}
  defp ends_at("forever", _date), do: {:ok, @forever}

  defp ends_at("date", date) do
    with {:ok, date} <- Date.from_iso8601(date || ""),
         {:ok, until} <- DateTime.new(date, ~T[00:00:00]),
         true <- DateTime.after?(until, DateTime.utc_now()) do
      {:ok, until}
    else
      _invalid_or_past -> {:error, :invalid_date}
    end
  end

  defp ends_at(_duration, _date), do: {:error, :invalid_date}

  defp from_now(days), do: DateTime.add(DateTime.utc_now(:second), days, :day)

  defp reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :no_reason}
      reason -> {:ok, String.slice(reason, 0, 1_000)}
    end
  end

  defp reason(_reason), do: {:error, :no_reason}

  def message(:admin), do: "Admins can't be silenced or suspended."
  def message(:invalid_date), do: "Pick a duration, or a date in the future."
  def message(:no_reason), do: "Give a reason: the user will see it."

  @doc ~S|When a penalty ends, for messages: "until 8 Nov 2026, 14:00 UTC" or "permanently".|
  def ends_text(@forever), do: "permanently"
  def ends_text(%DateTime{} = until), do: Calendar.strftime(until, "until %-d %b %Y, %H:%M UTC")

  @doc "Why a suspended user can't log in."
  def suspended_message(%User{} = user),
    do:
      "Your account is suspended #{ends_text(user.suspended_until)}. Reason: #{user.suspend_reason}"

  defp tell(kind, user, until, reason) do
    subject =
      case kind do
        :silence -> "You've been silenced #{ends_text(until)}"
        :suspend -> "Your account has been suspended #{ends_text(until)}"
      end

    {:ok, _} =
      Forums.notify(user, %{
        kind: if(kind == :silence, do: "silenced", else: "suspended"),
        subject: subject,
        body: reason,
        url: Paths.user_url(user)
      })

    if user.email, do: email(user, subject, reason)
  end

  # Best effort: the penalty is already in force and the in-app
  # notification says the same, so a mail failure is only logged.
  defp email(user, subject, reason) do
    case user |> Emails.penalty(subject, reason) |> Mailer.deliver_now() do
      {:ok, _email} -> :ok
      {:error, error} -> email_failed(user, error)
    end
  rescue
    error -> email_failed(user, error)
  end

  defp email_failed(user, error),
    do: Logger.error("Penalty email to user #{user.id} failed: #{inspect(error)}")

  defp reload_pages(user), do: Session.reload_pages(user)
end
