defmodule Firefly.Accounts.MagicLinks do
  @moduledoc """
  Logging in with a link sent by email ("magic links").

  Someone gives an email address; each account with that address,
  confirmed, gets a link (and nobody learns whether any exists). With the
  `magic_link_signup` site setting on (and registrations open), an address
  no account has gets a link that creates one, its email confirmed by
  following it.

  A link carries 32 random bytes; only their SHA-256 hash is stored. It
  works once, for 15 minutes. Following it shows a page whose button logs
  in (a POST), so email scanners that fetch links don't use them up.
  The login still asks for the second factor of a user with two-factor
  authentication (see `FireflyWeb.Login`).

  Requests are rate-limited per client IP and per address (the `:email`
  bucket for accounts). Links work while the `magic_links` site setting is
  on and passwords are (they're off when single sign-on is the only way
  in).
  """
  require Logger

  import Ecto.Query

  alias Firefly.{Accounts, Mailer, RateLimit, Repo, SiteSettings}
  alias Firefly.Accounts.{Auth, User}
  alias Firefly.Notifications.Emails
  alias Firefly.Plugins.Events

  @minutes 15

  @doc "Whether email login links are on."
  def enabled?, do: SiteSettings.get("magic_links") and Auth.password_login?()

  @doc "Whether an address without an account may sign up by link."
  def signup?,
    do: enabled?() and SiteSettings.get("magic_link_signup") and Accounts.registration_open?()

  @doc """
  Sends login links for `email` (see the moduledoc), as asked from
  `remote_ip`. Returns `:ok` whatever happened, or `{:error,
  :rate_limited}`.
  """
  def deliver(email, remote_ip) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    with true <- enabled?() || {:error, :disabled},
         :ok <- RateLimit.check(:magic_link, "ip:#{format_ip(remote_ip)}"),
         :ok <- RateLimit.check(:magic_link, "email:#{email}") do
      if String.match?(email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/), do: send_links(email)
      :ok
    end
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: to_string(ip)

  defp send_links(email) do
    case confirmed_users(email) do
      [] ->
        if signup?(), do: send_link(nil, email)

      users ->
        for user <- users, RateLimit.check_email(user) == :ok, do: send_link(user, email)
    end
  end

  defp confirmed_users(email) do
    Repo.all(
      from(u in User,
        where: fragment("lower(?)", u.email) == ^email,
        where: not is_nil(u.confirmed_at) and is_nil(u.deleted_at) and is_nil(u.plugin_bot)
      )
    )
  end

  defp send_link(user, email) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now(:second)

    Repo.delete_all(from(t in "magic_link_tokens", where: t.expires_at < ^now))

    Repo.insert_all("magic_link_tokens", [
      %{
        user_id: user && user.id,
        email: email,
        token_hash: hash(token),
        expires_at: DateTime.add(now, @minutes, :minute),
        inserted_at: now
      }
    ])

    (user || email)
    |> Emails.magic_link(Firefly.URLs.magic_link_url(token))
    |> Mailer.deliver_now()
  rescue
    error -> Logger.error("Failed to send a login link: #{Exception.message(error)}")
  end

  defp hash(token), do: :sha256 |> :crypto.hash(token) |> Base.encode16(case: :lower)

  @doc """
  What a link is for, without using it up: `{:ok, %User{}}` (a login),
  `{:ok, email}` (a sign-up) or `{:error, :invalid}`.
  """
  def peek(token) when is_binary(token) do
    case Repo.one(select(valid(token), [t], {t.user_id, t.email})) do
      nil -> {:error, :invalid}
      {nil, email} -> {:ok, email}
      {user_id, _email} -> user(user_id)
    end
  end

  def peek(_token), do: {:error, :invalid}

  @doc """
  Uses up a link: `{:ok, user}` for the account it logs into (created for
  a sign-up link), or `{:error, reason}` (`:invalid`, or registration
  errors).
  """
  def redeem(token) when is_binary(token) do
    with true <- enabled?() || {:error, :invalid} do
      now = DateTime.utc_now(:second)

      # Only the first of two clicks racing with one link gets it.
      case Repo.update_all(select(valid(token), [t], {t.user_id, t.email}), set: [used_at: now]) do
        {1, [{nil, email}]} -> sign_up(email)
        {1, [{user_id, _email}]} -> user(user_id)
        _none -> {:error, :invalid}
      end
    end
  end

  def redeem(_token), do: {:error, :invalid}

  defp valid(token) do
    now = DateTime.utc_now(:second)

    from(t in "magic_link_tokens",
      where: t.token_hash == ^hash(token) and is_nil(t.used_at) and t.expires_at > ^now
    )
  end

  defp user(id) do
    case Repo.get(User, id) do
      %User{deleted_at: nil} = user -> {:ok, user}
      _gone -> {:error, :invalid}
    end
  end

  # The address may have gained an account since the link was sent.
  defp sign_up(email) do
    case confirmed_users(email) do
      [user | _] -> {:ok, user}
      [] -> if signup?(), do: create_account(email), else: {:error, :invalid}
    end
  end

  defp create_account(email) do
    result =
      %User{confirmed_at: DateTime.utc_now(:second)}
      |> User.changeset(%{
        username: Auth.free_username(%{email: email}, "email"),
        name: email |> String.split("@") |> hd(),
        email: email
      })
      |> Repo.insert()

    with {:ok, user} <- result do
      Events.emit("user_registered", %{user: %{id: user.id, username: user.username}})
      {:ok, user}
    end
  end
end
