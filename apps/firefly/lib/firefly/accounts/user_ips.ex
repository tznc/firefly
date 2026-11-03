defmodule Firefly.Accounts.UserIPs do
  @moduledoc """
  The IP addresses members use the site from, for staff (the users admin
  shows them with when each was first and last seen, and the other
  accounts that used the same address). Recorded when a logged-in page
  connects (see `FireflyWeb.UserAuth`), at most every ten minutes per
  address, and removed with the account.
  """

  import Ecto.Query

  alias Firefly.Repo
  alias Firefly.Accounts.User

  @refresh_seconds 600

  @doc "Records that `user` is using the site from `ip` (a tuple or text) now."
  def record(%User{id: user_id}, ip) when not is_nil(ip) do
    if not Firefly.Backups.read_only?() do
      now = DateTime.utc_now(:second)
      stale = DateTime.add(now, -@refresh_seconds)

      Repo.insert_all(
        "user_ips",
        [%{user_id: user_id, ip: format(ip), first_seen_at: now, last_seen_at: now}],
        on_conflict:
          from(i in "user_ips",
            where: i.last_seen_at < ^stale,
            update: [set: [last_seen_at: ^now]]
          ),
        conflict_target: [:user_id, :ip]
      )
    end

    :ok
  end

  def record(_user, _ip), do: :ok

  @doc "`user`'s addresses, last seen first: maps with `ip`, `first_seen_at` and `last_seen_at`."
  def for_user(%User{id: user_id}) do
    Repo.all(
      from(i in "user_ips",
        where: i.user_id == ^user_id,
        order_by: [desc: i.last_seen_at],
        select: %{ip: i.ip, first_seen_at: i.first_seen_at, last_seen_at: i.last_seen_at}
      )
    )
  end

  @doc "The other (not deleted) accounts seen at any of `user`'s addresses, by username."
  def sharing(%User{id: user_id}) do
    ips = from(i in "user_ips", where: i.user_id == ^user_id, select: i.ip)

    Repo.all(
      from(u in User,
        join: i in "user_ips",
        on: i.user_id == u.id,
        where: i.ip in subquery(ips) and u.id != ^user_id and is_nil(u.deleted_at),
        distinct: true,
        order_by: u.username
      )
    )
  end

  @doc "The ids of accounts seen at `ip` (for searching the users admin by address)."
  def user_ids_at(ip),
    do: from(i in "user_ips", where: i.ip == ^String.trim(ip), select: i.user_id)

  defp format(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format(ip), do: to_string(ip)
end
