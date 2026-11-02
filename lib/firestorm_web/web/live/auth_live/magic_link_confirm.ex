defmodule FirestormWeb.Web.AuthLive.MagicLinkConfirm do
  @moduledoc """
  The page an emailed login link opens (see `FirestormWeb.MagicLinks`):
  says which account it logs into (or creates), and its button uses the
  link (`FirestormWeb.Web.MagicLinkController`). Opening the page doesn't,
  so email scanners can't use links up.
  """
  use FirestormWeb.Web, :live_view

  alias FirestormWeb.MagicLinks
  alias FirestormWeb.Forums.User

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    target = if MagicLinks.enabled?(), do: MagicLinks.peek(token), else: {:error, :invalid}
    {:ok, assign(socket, page_title: "Log in", token: token, target: target)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-4 py-8 text-center">
        <%= case @target do %>
          <% {:ok, %User{} = user} -> %>
            <.page_header title={"Log in as @#{user.username}"} />
            <.form for={%{}} id="magic-link-login" action={~p"/login/email/#{@token}"} method="post">
              <.button variant="primary" class="btn btn-primary w-full">Log in</.button>
            </.form>
          <% {:ok, email} -> %>
            <.page_header title="Create your account">
              <:subtitle>For {email}</:subtitle>
            </.page_header>
            <.form for={%{}} id="magic-link-login" action={~p"/login/email/#{@token}"} method="post">
              <.button variant="primary" class="btn btn-primary w-full">Create account and log in</.button>
            </.form>
          <% {:error, _} -> %>
            <.page_header title="That link doesn't work">
              <:subtitle>It expired or was used already.</:subtitle>
            </.page_header>
            <.link navigate={~p"/login/email"} class="btn">Send a new link</.link>
        <% end %>
      </section>
    </Layouts.app>
    """
  end
end
