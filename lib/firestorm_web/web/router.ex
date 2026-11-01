defmodule FirestormWeb.Web.Router do
  use Phoenix.Router, helpers: true

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  # Kaffy generates admin routes under /admin, behind the :admin pipeline.
  use Kaffy.Routes, scope: "/admin", pipe_through: [:admin]

  pipeline :webhook do
    plug(:accepts, ["json"])
  end

  pipeline :browser do
    plug(Ueberauth)
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {FirestormWeb.Web.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(FirestormWeb.Web.Plugs.CurrentUser)
  end

  pipeline :admin do
    plug(FirestormWeb.Web.Plugs.CurrentUser)
    plug(FirestormWeb.Web.Plugs.RequireAdmin)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    # The API authenticates with bearer tokens (not cookies), so any origin may call it.
    plug(CORSPlug)
    plug(FirestormWeb.Web.Plugs.ApiCurrentUser)
  end

  scope "/", FirestormWeb.Web do
    pipe_through(:browser)

    live_session :default, on_mount: [{FirestormWeb.Web.UserAuth, :mount_current_user}] do
      # Declared first so that e.g. /categories/new wins over /categories/:id.
      # These LiveViews also run `on_mount {UserAuth, :require_user}`.
      live("/threads/watching", ThreadLive.Watching, :index)
      live("/threads/participating", ThreadLive.Participating, :index)
      live("/notifications", NotificationLive.Index, :index)
      live("/notifications/:id", NotificationLive.Show, :show)
      live("/users/:id/edit", UserLive.Edit, :edit)
      live("/categories/new", CategoryLive.Form, :new)
      live("/categories/:id/edit", CategoryLive.Form, :edit)
      live("/categories/:category_id/threads/new", ThreadLive.New, :new)
      live("/categories/:category_id/threads/:id/edit", ThreadLive.Edit, :edit)
      live("/categories/:category_id/threads/:thread_id/posts/new", PostLive.New, :new)

      live("/", ThreadLive.Recent, :index)
      live("/login", AuthLive.Login, :login)
      live("/auth/identity", AuthLive.Identity, :new)
      live("/register", AuthLive.Registration, :new)
      live("/users", UserLive.Index, :index)
      live("/users/:id", UserLive.Show, :show)
      live("/categories", CategoryLive.Index, :index)
      live("/categories/:id", CategoryLive.Show, :show)
      live("/categories/:category_id/threads", ThreadLive.Index, :index)
      live("/categories/:category_id/threads/:id", ThreadLive.Show, :show)
    end
  end

  scope "/auth", FirestormWeb.Web do
    pipe_through(:browser)

    # DELETE only: a GET would let any page log users out (CSRF).
    delete("/logout", AuthController, :delete)
    get("/:provider", AuthController, :request)
    get("/:provider/callback", AuthController, :callback)
    post("/:provider/callback", AuthController, :callback)
  end

  # JSON API
  scope "/api/v1", FirestormWeb.Web.Api.V1 do
    pipe_through(:api)

    resources("/preview", PreviewController, only: [:create])
    resources("/upload_signature", UploadSignatureController, only: [:create])
    resources("/posts", PostController, only: [:create])
    post("/auth/identity", AuthController, :identity)
  end

  # Inbound email webhooks
  scope "/inbound", FirestormWeb.Web do
    pipe_through(:webhook)

    post("/sendgrid", InboundController, :sendgrid)
  end

  if Application.compile_env(:firestorm_web, :dev_routes) do
    forward("/sent_emails", Bamboo.SentEmailViewerPlug)
  end
end
