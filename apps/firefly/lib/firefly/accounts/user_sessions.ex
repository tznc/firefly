defmodule Firefly.Accounts.UserSessions do
  @moduledoc """
  Server-side sessions: each logged-in browser is a `UserSession` row, and
  its cookie holds only a random token (stored hashed). Every request and
  every LiveView mount checks it (`get_user/2`), so a session can be ended
  from anywhere:

    * members see their devices in their security settings and sign any
      out (`revoke/2`), or all the others (`revoke_all/2`);
    * a password reset and a suspension sign out every session, and staff
      can sign a member out everywhere;
    * a session not seen for `session_idle_hours` (setting, default 168)
      ends, and none lasts longer than `session_remember_days` (default 30),
      the lifetime of the "keep me logged in" cookie too.

  A revoked session's LiveView sockets are disconnected at once: each
  session's sockets share `live_socket_id/1` (stored as `"live_socket_id"`
  in its cookie at login), and revoking broadcasts `"disconnect"` to it.
  Expired rows are deleted hourly (`run_cleanup/1`).

  Multi-tenancy: sessions are tenant data, and the socket ids get the
  tenant's topic prefix.
  """

  import Ecto.Query

  alias Firefly.{Endpoint, Notifications, Repo, Security, SiteSettings}
  alias Firefly.Accounts.{User, UserSession}

  # How stale last_seen_at may get before a request refreshes it.
  @touch_seconds 300

  @doc """
  Starts a session for `user`: `{token, session}`, the token going in the
  browser's cookie. Options: `:remember`, `:ip`, `:user_agent`.
  """
  def create(%User{id: user_id}, opts \\ []) do
    token = :crypto.strong_rand_bytes(32)
    now = DateTime.utc_now(:second)
    agent = opts[:user_agent] && String.slice(opts[:user_agent], 0, 512)

    session =
      Repo.insert!(%UserSession{
        user_id: user_id,
        token_hash: hash(token),
        remember: opts[:remember] == true,
        ip: format_ip(opts[:ip]),
        user_agent: agent,
        device: device(agent),
        last_seen_at: now,
        inserted_at: now
      })

    {Base.url_encode64(token, padding: false), session}
  end

  defp hash(token), do: :crypto.hash(:sha256, token)

  @doc """
  The user and session `token` (from a cookie) belongs to, if the session
  is still live and its user may still log in: `{user, session}` or nil.
  Refreshes when it was last seen (and from where, `:ip`) at most every
  five minutes.
  """
  def get_user(token, opts \\ [])

  def get_user(token, opts) when is_binary(token) do
    now = DateTime.utc_now(:second)

    with {:ok, raw} <- Base.url_decode64(token, padding: false),
         %UserSession{user: %User{deleted_at: nil} = user} = session <-
           Repo.one(from(s in UserSession, where: s.token_hash == ^hash(raw), preload: :user)),
         false <- User.suspended?(user),
         true <- live?(session, now) do
      {user, touch(session, now, opts)}
    else
      _ -> nil
    end
  end

  def get_user(_token, _opts), do: nil

  defp live?(session, now) do
    DateTime.diff(now, session.last_seen_at, :hour) < SiteSettings.get("session_idle_hours") and
      DateTime.diff(now, session.inserted_at, :day) < SiteSettings.get("session_remember_days")
  end

  defp touch(session, now, opts) do
    ip = format_ip(opts[:ip]) || session.ip

    if DateTime.diff(now, session.last_seen_at) >= @touch_seconds or ip != session.ip do
      session |> Ecto.Changeset.change(last_seen_at: now, ip: ip) |> Repo.update!()
    else
      session
    end
  end

  @doc "`user`'s live sessions, last seen first."
  def list(%User{id: user_id}) do
    now = DateTime.utc_now(:second)

    UserSession
    |> where([s], s.user_id == ^user_id)
    |> order_by(desc: :last_seen_at, desc: :id)
    |> Repo.all()
    |> Enum.filter(&live?(&1, now))
  end

  @doc "One of `user`'s sessions by id, or nil."
  def get(%User{id: user_id}, id), do: Repo.get_by(UserSession, id: id, user_id: user_id)

  @doc "Ends `session`: its cookie stops working and its open pages disconnect."
  def revoke(%UserSession{} = session, details \\ %{}) do
    Repo.delete!(session, allow_stale: true)
    Endpoint.broadcast(live_socket_id(session), "disconnect", %{})
    Security.record("session.revoke", session.user_id, Map.put(details, :device, session.device))
    :ok
  end

  @doc """
  Ends every session of `user` but `except` (a session id; nil: all), with
  `details` for the security log (e.g. `%{reason: "password reset"}`).
  """
  def revoke_all(%User{id: user_id}, except \\ nil, details \\ %{}) do
    UserSession
    |> where([s], s.user_id == ^user_id)
    |> Repo.all()
    |> Enum.reject(&(&1.id == except))
    |> Enum.each(&revoke(&1, details))
  end

  @doc "Deletes sessions past their idle time or lifetime (hourly, see `Firefly.Jobs.Periodic`)."
  def run_cleanup(now \\ DateTime.utc_now()) do
    idle = DateTime.add(now, -SiteSettings.get("session_idle_hours"), :hour)
    born = DateTime.add(now, -SiteSettings.get("session_remember_days"), :day)

    {count, _} =
      Repo.delete_all(
        from(s in UserSession, where: s.last_seen_at < ^idle or s.inserted_at < ^born)
      )

    count
  end

  @doc "The id the LiveView sockets of `session` share."
  def live_socket_id(%UserSession{id: id}), do: "user_sessions:#{id}"

  @doc """
  Makes every open page of `user` pick up a change to their account (a
  penalty, deletion): their sessions' sockets are disconnected (and
  reconnect, mounting with the change), and pages also reload themselves on
  the user's notification topic.
  """
  def reload_pages(%User{} = user) do
    for session <- Repo.all(from(s in UserSession, where: s.user_id == ^user.id)),
        do: Endpoint.broadcast(live_socket_id(session), "disconnect", %{})

    Phoenix.PubSub.broadcast(
      Firefly.PubSub,
      Notifications.notifications_topic(user.id),
      :account_changed
    )
  end

  @doc ~S'A label for a browser from its user agent, like "Firefox on macOS".'
  def device(nil), do: nil

  def device(agent) do
    browser =
      Enum.find_value(
        [
          {"Edg/", "Edge"},
          {"OPR/", "Opera"},
          {"Firefox/", "Firefox"},
          {"Chrome/", "Chrome"},
          {"Safari/", "Safari"}
        ],
        "A browser",
        fn {marker, name} -> if String.contains?(agent, marker), do: name end
      )

    os =
      Enum.find_value(
        [
          {"iPhone", "iOS"},
          {"iPad", "iPadOS"},
          {"Android", "Android"},
          {"Windows", "Windows"},
          {"Mac OS X", "macOS"},
          {"CrOS", "ChromeOS"},
          {"Linux", "Linux"}
        ],
        fn {marker, name} -> if String.contains?(agent, marker), do: name end
      )

    if os, do: "#{browser} on #{os}", else: browser
  end

  defp format_ip(nil), do: nil
  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: ip |> to_string() |> String.slice(0, 45)
end
