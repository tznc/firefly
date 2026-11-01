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

    get("/users/:id/edit", UserController, :edit)
    get("/settings/export", AccountController, :export)
    delete("/settings/account", AccountController, :delete)

    live_session :default, on_mount: [{FirestormWeb.Web.UserAuth, :mount_current_user}] do
      # Declared first so that e.g. /categories/new wins over /categories/:id.
      # These LiveViews also run `on_mount {UserAuth, :require_user}`.
      live("/threads/watching", ThreadLive.Watching, :index)
      live("/threads/participating", ThreadLive.Participating, :index)
      live("/new", ThreadLive.NewThreads, :index)
      live("/settings", SettingsLive.Index, :profile)
      live("/settings/profile", SettingsLive.Index, :profile)
      live("/settings/interface", SettingsLive.Index, :interface)
      live("/settings/notifications", SettingsLive.Index, :notifications)
      live("/settings/privacy", SettingsLive.Index, :privacy)
      live("/settings/account", SettingsLive.Index, :account)
      live("/unread", ThreadLive.Unread, :index)
      live("/drafts", DraftLive.Index, :index)
      live("/notifications", NotificationLive.Index, :index)
      live("/messages", MessageLive.Index, :index)
      live("/messages/new", MessageLive.New, :new)
      live("/messages/:id", MessageLive.Show, :show)
      live("/notifications/:id", NotificationLive.Show, :show)
      live("/staff/log", StaffLive.Log, :index)
      live("/staff/settings", StaffLive.Settings, :index)
      live("/staff/groups", StaffLive.Groups, :index)
      live("/staff/review", StaffLive.Review, :index)
      live("/staff/tags", StaffLive.Tags, :index)
      live("/categories/new", CategoryLive.Form, :new)
      live("/categories/:id/edit", CategoryLive.Form, :edit)
      live("/categories/:category_id/threads/new", ThreadLive.New, :new)
      live("/categories/:category_id/threads/:id/edit", ThreadLive.Edit, :edit)
      live("/categories/:category_id/threads/:id/tools", ThreadLive.Tools, :edit)
      live("/categories/:category_id/threads/:thread_id/posts/new", PostLive.New, :new)
      live("/categories/:category_id/threads/:thread_id/posts/:id/edit", PostLive.Edit, :edit)

      live("/", ThreadLive.Recent, :index)
      live("/top", ThreadLive.Top, :index)
      live("/login", AuthLive.Login, :login)
      live("/auth/identity", AuthLive.Identity, :new)
      live("/register", AuthLive.Registration, :new)
      live("/reset-password", AuthLive.ForgotPassword, :new)
      live("/reset-password/:token", AuthLive.ResetPassword, :edit)
      live("/users", UserLive.Index, :index)
      live("/users/:id", UserLive.Show, :show)
      live("/search", SearchLive.Index, :index)
      live("/tags", TagLive.Index, :index)
      live("/tags/:name", TagLive.Show, :show)
      live("/categories", CategoryLive.Index, :index)
      live("/categories/:id", CategoryLive.Show, :show)
      live("/categories/:category_id/threads", ThreadLive.Index, :index)
      live("/categories/:category_id/threads/:id", ThreadLive.Show, :show)

      live(
        "/categories/:category_id/threads/:thread_id/posts/:id/history",
        PostLive.History,
        :show
      )
    end
  end

  scope "/confirm", FirestormWeb.Web do
    pipe_through(:browser)

    get("/:token", ConfirmationController, :confirm)
    post("/", ConfirmationController, :resend)
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
    get("/search", SearchController, :index)
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
