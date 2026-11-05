defmodule FireflyWeb.SecurityComponents do
  @moduledoc """
  The security log (see `Firefly.Security`) as members see their own
  (`/settings/security`) and admins see everyone's (`/staff/security`).
  """
  use Phoenix.Component
  use Gettext, backend: FireflyWeb.Gettext

  import FireflyWeb.ForumComponents, only: [time_ago: 1]

  @doc "What an event of `kind` means, in words."
  def event_label("login.success"), do: gettext("Logged in")
  def event_label("login.failure"), do: gettext("Failed login")
  def event_label("two_factor.failure"), do: gettext("Wrong two-factor code")
  def event_label("passkey.failure"), do: gettext("Passkey refused")
  def event_label("two_factor.enable"), do: gettext("Two-factor authentication turned on")
  def event_label("two_factor.disable"), do: gettext("Authenticator app turned off")
  def event_label("two_factor.backup_codes"), do: gettext("New backup codes")
  def event_label("two_factor.key_add"), do: gettext("Security key added")
  def event_label("two_factor.key_remove"), do: gettext("Security key removed")
  def event_label("two_factor.reset"), do: gettext("Two-factor authentication reset by staff")
  def event_label("passkey.add"), do: gettext("Passkey added")
  def event_label("passkey.remove"), do: gettext("Passkey removed")
  def event_label("password.reset"), do: gettext("Password changed")
  def event_label("api_key.create"), do: gettext("API key created")
  def event_label("api_key.use"), do: gettext("API key used from a new address")
  def event_label("api_key.revoke"), do: gettext("API key revoked")
  def event_label("session.revoke"), do: gettext("Signed out a device")
  def event_label("account.suspend"), do: gettext("Account suspended")
  def event_label("account.unsuspend"), do: gettext("Suspension lifted")
  def event_label("account.silence"), do: gettext("Account silenced")
  def event_label("account.unsilence"), do: gettext("Silence lifted")
  def event_label("ip.ban"), do: gettext("IP address banned")
  def event_label("ip.unban"), do: gettext("IP address unbanned")
  def event_label("upload.quarantine"), do: gettext("Upload quarantined by the virus scanner")
  def event_label(kind), do: kind

  attr :id, :string, required: true
  attr :events, :list, required: true
  attr :show_user, :boolean, default: false, doc: "a column with each event's member"

  @doc "A table of security events, newest first."
  def events_table(assigns) do
    ~H"""
    <div class="overflow-x-auto">
      <table id={@id} class="table table-sm">
        <thead>
          <tr>
            <th>{gettext("When")}</th>
            <th :if={@show_user}>{gettext("Member")}</th>
            <th>{gettext("Event")}</th>
            <th>{gettext("IP address")}</th>
            <th>{gettext("Browser")}</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={event <- @events} id={"#{@id}-#{event.id}"} data-kind={event.kind}>
            <td class="whitespace-nowrap">
              <.time_ago at={event.inserted_at} id={"#{@id}-#{event.id}-at"} />
            </td>
            <td :if={@show_user}>
              <a :if={event.user} href={"/staff/users/#{event.user_id}"} class="link">
                {event.user.username}
              </a>
            </td>
            <td>
              {event_label(event.kind)}
              <span :if={event.details["method"]} class="text-base-content/70">
                ({event.details["method"]})
              </span>
              <span :if={event.details["name"]} class="text-base-content/70">
                “{event.details["name"]}”
              </span>
            </td>
            <td class="font-mono text-xs">{event.ip}</td>
            <td class="max-w-xs truncate text-xs" title={event.user_agent}>{event.user_agent}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
