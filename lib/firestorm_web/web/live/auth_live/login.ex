defmodule FirestormWeb.Web.AuthLive.Login do
  @moduledoc """
  Choose how to log in: single sign-on or a social login (one button per
  enabled provider; see `FirestormWeb.Auth`) or a username and password
  (unless single sign-on is the only way in).
  """
  use FirestormWeb.Web, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Log in")
     |> assign(:providers, FirestormWeb.Auth.enabled_providers())
     |> assign(:password_login, FirestormWeb.Auth.password_login?())}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <section class="mx-auto max-w-sm space-y-6 py-8 text-center">
        <.link navigate={~p"/categories"} class="inline-flex justify-center">
          <Layouts.logo size="size-12" class="text-3xl" />
        </.link>
        <div class="card border border-base-300 bg-base-100">
          <div class="card-body gap-3">
            <a
              :for={provider <- @providers}
              href={~p"/auth/#{provider}"}
              id={"login-#{provider}"}
              class="btn btn-neutral"
            >
              Log in with {FirestormWeb.Auth.label(provider)}
            </a>
            <div :if={@providers != [] and @password_login} class="divider text-xs">or</div>
            <.link
              :if={@password_login and FirestormWeb.Forums.registration_open?()}
              navigate={~p"/register"}
              class="btn btn-primary"
            >
              Create Account
            </.link>
            <.link :if={@password_login} navigate={~p"/auth/identity"} class="link text-sm">
              Sign In
            </.link>
          </div>
        </div>
        <p class="text-xs text-base-content/60">
          By signing up, I agree to {FirestormWeb.SiteSettings.get("title")}'s Terms and Privacy Policy.
        </p>
        <p class="text-xs text-base-content/60">
          Firefly is made by <a href="https://tznc.dev" class="link">tznc.dev</a>
        </p>
      </section>
    </Layouts.app>
    """
  end
end
