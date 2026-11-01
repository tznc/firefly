defmodule FirestormWeb.Web.AuthLive.Login do
  @moduledoc "Choose how to log in: GitHub or a username and password."
  use FirestormWeb.Web, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Log in")}

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
            <a href={~p"/auth/github"} class="btn btn-neutral">
              <.icon name="hero-code-bracket" class="size-5" /> Log in with GitHub
            </a>
            <div class="divider text-xs">or</div>
            <.link navigate={~p"/auth/identity"} class="btn btn-primary">Create Account</.link>
            <.link navigate={~p"/auth/identity"} class="link text-sm">Sign In</.link>
          </div>
        </div>
        <p class="text-xs text-base-content/60">
          By signing up, I agree to Firefly's Terms and Privacy Policy.
        </p>
        <p class="text-xs text-base-content/60">
          Firefly is made by <a href="https://tznc.dev" class="link">tznc.dev</a>
        </p>
      </section>
    </Layouts.app>
    """
  end
end
