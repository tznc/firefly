defmodule FireflyWeb.StaffLive.ApiKeys do
  @moduledoc """
  Every API key (admins only; see `Firefly.Accounts.ApiKeys`): who it's
  for, its scopes and last use, revoking any of them, and creating global
  keys (`FireflyWeb.ApiKeysComponent`).
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_api_keys) do
      {:ok, assign(socket, :page_title, "API keys")}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="API keys" navigate={~p"/staff/api-keys"}>
        <:subtitle>Members' keys and global keys for the API.</:subtitle>
      </.page_header>

      <.live_component module={FireflyWeb.ApiKeysComponent} id="api-keys" current_user={@current_user} mode={:all} />
    </Layouts.app>
    """
  end
end
