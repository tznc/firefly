defmodule FireflyWeb.SAMLController do
  @moduledoc """
  Logging in with a SAML identity provider (see `Firefly.Accounts.Auth.SAML`):

    * `request` records a login request (its id kept in this session) and
      sends the browser to the identity provider;
    * `acs`, the assertion consumer service, takes the identity provider's
      posted response. It arrives without our session cookie (a cross-site
      POST; the cookie is SameSite=Lax), so it neither reads nor writes the
      session: it verifies and stores the answer, then sends the browser on
      to `finish`, errors included;
    * `finish` (a plain GET, so the session comes along) takes the answer to
      this session's request and logs in, or, for a user already logged in,
      connects the account to them (from the settings' Logins tab). An
      unsolicited login, when allowed, comes with a one-time ticket instead
      and can only log in, never connect;
    * `metadata` is our service provider metadata, for the identity provider.
  """
  use FireflyWeb, :controller

  alias Firefly.Accounts.{Auth, User}
  alias Firefly.Accounts.Auth.SAML
  alias FireflyWeb.{InviteController, Login}

  # Only the reasons with a message of their own travel in the URL.
  @errors ~w(expired unknown_request replayed login_failed unsolicited not_configured metadata_unavailable)a

  def request(conn, params) do
    return_to = Login.local_path(params["return_to"] || "/")

    case SAML.request(return_to) do
      {:ok, id, url} ->
        conn
        |> put_session(:saml_request, id)
        |> redirect(external: url)

      {:error, reason} ->
        Login.fail(conn, ~p"/login", SAML.message(reason))
    end
  end

  def acs(conn, params) do
    case SAML.consume(params["SAMLResponse"], params["RelayState"]) do
      {:ok, :solicited} -> redirect(conn, to: ~p"/auth/saml/finish")
      {:ok, {:unsolicited, ticket}} -> redirect(conn, to: ~p"/auth/saml/finish?ticket=#{ticket}")
      {:error, reason} -> redirect(conn, to: ~p"/auth/saml/finish?error=#{error_code(reason)}")
    end
  end

  defp error_code(reason) when reason in @errors, do: reason
  defp error_code(_reason), do: :failed

  def finish(conn, %{"error" => code}) do
    reason = Enum.find(@errors, :failed, &(Atom.to_string(&1) == code))

    conn
    |> delete_session(:saml_request)
    |> Login.fail(~p"/login", SAML.message(reason))
  end

  def finish(conn, %{"ticket" => ticket}) do
    case SAML.take(ticket) do
      {:ok, answer} -> log_in(conn, answer)
      {:error, reason} -> Login.fail(conn, ~p"/login", SAML.message(reason))
    end
  end

  def finish(conn, _params) do
    request = get_session(conn, :saml_request)
    conn = delete_session(conn, :saml_request)

    case SAML.take(request) do
      {:ok, answer} -> finish_request(conn, answer)
      {:error, reason} -> Login.fail(conn, ~p"/login", SAML.message(reason))
    end
  end

  defp finish_request(%{assigns: %{current_user: %User{} = user}} = conn, answer) do
    label = SAML.label()

    case Auth.connect(user, SAML.info(answer.result)) do
      {:ok, _identity} ->
        SAML.sync(user, answer.result)

        conn
        |> put_flash(:info, "#{label} account connected.")
        |> redirect(to: ~p"/settings/logins")

      {:error, message} ->
        conn
        |> put_flash(:error, "That #{label} account #{message}.")
        |> redirect(to: ~p"/settings/logins")
    end
  end

  defp finish_request(conn, answer), do: log_in(conn, answer)

  defp log_in(conn, answer) do
    {invite, conn} = InviteController.take_invite(conn)
    to = if invite, do: InviteController.destination(invite), else: answer.return_to

    case SAML.login(answer.result, invite) do
      {:ok, user} -> Login.complete(conn, user, ~p"/login", :sso, Login.local_path(to))
      {:error, reason} -> Login.fail(conn, ~p"/login", reason)
    end
  end

  def metadata(conn, _params) do
    conn
    |> put_resp_content_type("application/samlmetadata+xml")
    |> send_resp(200, SAML.metadata())
  end
end
