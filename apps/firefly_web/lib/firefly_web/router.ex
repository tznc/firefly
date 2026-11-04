defmodule FireflyWeb.Router do
  use Phoenix.Router, helpers: true

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :webhook do
    plug(:accepts, ["json"])
  end

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(FireflyWeb.Plugs.LoginProviders)
    plug(Ueberauth)
    plug(:put_root_layout, html: {FireflyWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(FireflyWeb.Plugs.CurrentUser)
    plug(FireflyWeb.Locale)
    plug(FireflyWeb.Plugs.AkismetClient)
    plug(FireflyWeb.Plugs.Analytics, :browser)
    plug(FireflyWeb.Plugs.CrawlerView)
  end

  pipeline :admin do
    plug(FireflyWeb.Plugs.CurrentUser)
    plug(FireflyWeb.Plugs.RequireAdmin)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    # The API authenticates with bearer tokens (not cookies), so any origin may call it.
    plug(CORSPlug)
    plug(FireflyWeb.Plugs.ApiCurrentUser, strict: true)
    plug(FireflyWeb.Plugs.AkismetClient)
    plug(FireflyWeb.Plugs.Analytics, :api)
    plug(FireflyWeb.Plugs.ReadOnly)
  end

  # Uploads are fetched by <img> tags and downloads, so any Accept; the
  # session says who's asking (see FireflyWeb.UploadController).
  pipeline :uploads do
    plug(:fetch_session)
    plug(FireflyWeb.Plugs.CurrentUser)
  end

  # One-click unsubscribe (RFC 8058): mail clients POST without a session
  # or CSRF token; the signed token in the URL is the authorization.
  pipeline :one_click do
    plug(:accepts, ["html", "text"])
  end

  # A SAML identity provider's response, posted from its page: no session
  # (the browser doesn't send it) and no CSRF token; the signed response is
  # the authorization (see FireflyWeb.SAMLController).
  pipeline :saml_acs do
    plug(:accepts, ["html"])
  end

  pipeline :plugin_api do
    plug(FireflyWeb.Plugs.ApiCurrentUser)
    plug(FireflyWeb.Plugs.ReadOnly)
  end

  # Plugins' assets and widget SDK: served to sandboxed frames, so no
  # session or browser pipeline (see Firefly.Plugins.UI).
  scope "/plugins", FireflyWeb do
    get("/sdk.js", PluginController, :sdk)
    get("/:id/assets/*path", PluginController, :asset)
  end

  scope "/uploads", FireflyWeb do
    pipe_through(:uploads)

    get("/:token/thumb/:name", UploadController, :thumbnail)
    get("/:token/:name", UploadController, :show)
  end

  scope "/avatars", FireflyWeb do
    pipe_through(:uploads)

    get("/:id", UploadController, :avatar)
    get("/:id/:size", UploadController, :avatar)
  end

  scope "/backgrounds", FireflyWeb do
    pipe_through(:uploads)

    get("/:id", UploadController, :background)
  end

  # Plugins' inbound endpoints, authenticated per plugin.
  scope "/api/plugins", FireflyWeb do
    pipe_through(:plugin_api)

    match(:*, "/:id/*path", PluginController, :endpoint)
  end

  scope "/", FireflyWeb do
    pipe_through(:browser)

    get("/users/:id/edit", UserController, :edit)
    get("/settings/export", AccountController, :export)
    post("/login/two-factor", TwoFactorController, :create)
    post("/login/ldap", LDAPController, :create)
    get("/session/sso_provider", DiscourseConnectProviderController, :show)
    post("/login/two-factor/key", TwoFactorController, :key)
    get("/login/passkey/challenge", PasskeyController, :challenge)
    post("/login/passkey", PasskeyController, :create)
    post("/login/email/:token", MagicLinkController, :create)
    delete("/settings/account", AccountController, :delete)
    get("/invites/:key/login/:provider", InviteController, :login)

    live_session :default,
      session: {FireflyWeb.Plugs.Analytics, :live_session, []},
      on_mount: [
        {FireflyWeb.UserAuth, :mount_current_user},
        {FireflyWeb.Locale, :put_locale},
        FireflyWeb.PluginWidgets
      ] do
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
      live("/settings/users", SettingsLive.Index, :users)
      live("/settings/logins", SettingsLive.Index, :logins)
      live("/settings/security", SettingsLive.Index, :security)
      live("/settings/api-keys", SettingsLive.Index, :api_keys)
      live("/settings/account", SettingsLive.Index, :account)
      live("/unread", ThreadLive.Unread, :index)
      live("/invites", InviteLive.Index, :index)
      live("/drafts", DraftLive.Index, :index)
      live("/bookmarks", BookmarkLive.Index, :index)
      live("/notifications", NotificationLive.Index, :index)
      live("/messages", MessageLive.Index, :index)
      live("/messages/new", MessageLive.New, :new)
      live("/messages/:id", MessageLive.Show, :show)
      live("/notifications/:id", NotificationLive.Show, :show)
      live("/chat", ChatLive, :index)
      live("/chat/new-message", ChatLive, :new_dm)
      live("/chat/c/:slug/:id", ChatLive, :channel)
      live("/chat/c/:slug/:id/t/:message_id", ChatLive, :thread)
      live("/staff", StaffLive.Index, :index)
      live("/staff/users", StaffLive.Users, :index)
      live("/staff/users/:id", StaffLive.User, :show)
      live("/staff/categories", StaffLive.Categories, :index)
      live("/staff/emails", StaffLive.Emails, :index)
      live("/staff/screening", StaffLive.Screening, :index)
      live("/staff/dashboard", StaffLive.Dashboard, :index)
      live("/staff/reports", StaffLive.Reports, :index)
      live("/staff/reports/:id", StaffLive.Report, :show)
      live("/staff/backups", StaffLive.Backups, :index)
      live("/staff/import", StaffLive.Imports, :index)
      live("/staff/upgrade", StaffLive.Upgrade, :index)
      live("/staff/embedding", StaffLive.Embedding, :index)
      live("/staff/ai", StaffLive.AI, :index)
      live("/staff/log", StaffLive.Log, :index)
      live("/staff/settings", StaffLive.Settings, :index)
      live("/staff/groups", StaffLive.Groups, :index)
      live("/staff/review", StaffLive.Review, :index)
      live("/staff/tags", StaffLive.Tags, :index)
      live("/staff/plugins", StaffLive.Plugins, :index)
      live("/staff/uploads", StaffLive.Uploads, :index)
      live("/staff/emoji", StaffLive.Emoji, :index)
      live("/staff/watched-words", StaffLive.WatchedWords, :index)
      live("/staff/webhooks", StaffLive.Webhooks, :index)
      live("/staff/discourse-connect", StaffLive.DiscourseConnect, :index)
      live("/staff/webhooks/:id", StaffLive.Webhook, :show)
      live("/staff/api-keys", StaffLive.ApiKeys, :index)
      live("/staff/badges", StaffLive.Badges, :index)
      live("/staff/plugins/:id", StaffLive.Plugin, :show)
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
      live("/invites/:key", InviteLive.Show, :show)
      live("/email/unsubscribe/:token", DigestLive.Unsubscribe, :show)
      live("/login/two-factor", AuthLive.TwoFactor, :show)
      live("/login/email", AuthLive.MagicLink, :new)
      live("/login/email/:token", AuthLive.MagicLinkConfirm, :show)
      live("/auth/identity", AuthLive.Identity, :new)
      live("/login/ldap", AuthLive.LDAP, :new)
      live("/register", AuthLive.Registration, :new)
      live("/reset-password", AuthLive.ForgotPassword, :new)
      live("/reset-password/:token", AuthLive.ResetPassword, :edit)
      live("/users", UserLive.Index, :index)
      live("/users/:id", UserLive.Show, :show)
      live("/users/:id/summary", UserLive.Show, :summary)
      live("/users/:id/badges", UserLive.Show, :badges)
      live("/badges", BadgeLive.Index, :index)
      live("/badges/:id", BadgeLive.Show, :show)
      live("/groups", GroupLive.Index, :index)
      live("/groups/:name", GroupLive.Show, :about)
      live("/groups/:name/:tab", GroupLive.Show, :tab)
      live("/search", SearchLive.Index, :index)
      live("/plugins/:id", PluginLive.Page, :show)
      live("/plugins/:id/*path", PluginLive.Page, :show)
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

  # Blog comments: the script sites include, and the framed comments page
  # (see FireflyWeb.EmbedController). No session: it's public, and framed
  # cross-site, where cookies don't go anyway.
  pipeline :embed do
    plug(:accepts, ["html"])
  end

  get("/embed.js", FireflyWeb.EmbedController, :script)

  scope "/embed", FireflyWeb do
    pipe_through(:embed)

    get("/comments", EmbedController, :comments)
  end

  # Link click beacons (navigator.sendBeacon): no session or CSRF token,
  # they only add to a counter (see FireflyWeb.AnalyticsController).
  scope "/analytics", FireflyWeb do
    post("/click", AnalyticsController, :click)
  end

  # Reports as CSV, backup downloads, settings exports and starting to
  # impersonate, for admins.
  scope "/staff", FireflyWeb do
    pipe_through([:browser, :admin])

    get("/reports/:id/export", ReportController, :export)
    get("/backups/download/:token", BackupController, :download)
    post("/users/:id/impersonate", StaffController, :impersonate)
    get("/settings/export/:format", SettingsController, :export)
  end

  scope "/", FireflyWeb do
    pipe_through(:browser)

    # Ending an impersonation: the session's user is the member then, so
    # the impersonating admin is checked from the session instead.
    delete("/impersonate", StaffController, :stop_impersonating)
    # The admin used to be at /admin (Kaffy); it's the staff admin now.
    get("/admin", StaffController, :admin_moved)
    get("/admin/*path", StaffController, :admin_moved)
  end

  scope "/email", FireflyWeb do
    pipe_through(:one_click)

    post("/unsubscribe/:token", DigestController, :unsubscribe)
  end

  scope "/confirm", FireflyWeb do
    pipe_through(:browser)

    get("/:token", ConfirmationController, :confirm)
    post("/", ConfirmationController, :resend)
  end

  scope "/auth", FireflyWeb do
    pipe_through(:browser)

    # DELETE only: a GET would let any page log users out (CSRF).
    delete("/logout", AuthController, :delete)
    get("/discourse_connect", DiscourseConnectController, :request)
    get("/discourse_connect/callback", DiscourseConnectController, :callback)
    get("/ldap", LDAPController, :request)
    get("/saml", SAMLController, :request)
    get("/saml/finish", SAMLController, :finish)
    get("/:provider", AuthController, :request)
    get("/:provider/callback", AuthController, :callback)
    post("/:provider/callback", AuthController, :callback)
  end

  scope "/auth/saml", FireflyWeb do
    pipe_through(:saml_acs)

    post("/acs", SAMLController, :acs)
  end

  # SAML service provider metadata, for setting up the identity provider
  # (so before SAML logins are on, too).
  get("/saml/metadata", FireflyWeb.SAMLController, :metadata)

  # Crawlers: robots.txt and the sitemaps (see Firefly.SEO). No session.
  pipeline :crawlers do
    plug(:accepts, ["xml", "txt", "html"])
  end

  scope "/", FireflyWeb do
    pipe_through(:crawlers)

    get("/robots.txt", SitemapController, :robots)
    get("/sitemap.xml", SitemapController, :index)
    get("/sitemap/:name", SitemapController, :show)
  end

  # The API's reference, rendered from its OpenAPI document.
  get("/api/v1/docs", FireflyWeb.Api.V1.DocsController, :show)

  # JSON API (see FireflyWeb.Api.V1.OpenAPI for every operation).
  scope "/api/v1", FireflyWeb.Api.V1 do
    pipe_through(:api)

    get("/openapi.json", DocsController, :spec)

    post("/auth/identity", AuthController, :identity)
    get("/me", MeController, :show)
    patch("/me", MeController, :update)
    patch("/me/preferences", MeController, :preferences)

    get("/categories", CategoryController, :index)
    post("/categories", CategoryController, :create)
    get("/categories/:id", CategoryController, :show)
    patch("/categories/:id", CategoryController, :update)
    delete("/categories/:id", CategoryController, :delete)
    get("/categories/:id/threads", CategoryController, :threads)
    put("/categories/:id/notification-level", CategoryController, :notification_level)

    get("/threads", ThreadController, :index)
    post("/threads", ThreadController, :create)
    get("/threads/:id", ThreadController, :show)
    patch("/threads/:id", ThreadController, :update)
    delete("/threads/:id", ThreadController, :delete)
    get("/threads/:id/posts", ThreadController, :posts)
    post("/threads/:id/posts", ThreadController, :reply)
    post("/threads/:id/read", ThreadController, :read)
    put("/threads/:id/notification-level", ThreadController, :notification_level)
    post("/threads/:id/move", ThreadController, :move)
    put("/threads/:id/solution", ThreadController, :accept_answer)
    delete("/threads/:id/solution", ThreadController, :unaccept_answer)
    post("/threads/:id/:action", ThreadController, :moderate)

    post("/posts", PostController, :create)
    get("/posts/:id", PostController, :show)
    patch("/posts/:id", PostController, :update)
    delete("/posts/:id", PostController, :delete)
    post("/posts/:id/restore", PostController, :restore)
    put("/posts/:id/like", PostController, :like)
    delete("/posts/:id/like", PostController, :like)
    put("/posts/:id/bookmark", PostController, :bookmark)
    delete("/posts/:id/bookmark", PostController, :bookmark)
    post("/posts/:id/flags", PostController, :flag)
    put("/posts/:id/wiki", PostController, :wiki)
    get("/posts/:id/poll", PostController, :poll)
    post("/posts/:id/poll/vote", PostController, :vote)
    post("/posts/:id/poll/:action", PostController, :close_poll)
    get("/bookmarks", BookmarkController, :index)

    get("/tags", TagController, :index)
    get("/tags/:name/threads", TagController, :threads)
    put("/tags/:name/notification-level", TagController, :notification_level)

    get("/users", UserController, :index)
    get("/users/:username", UserController, :show)
    get("/users/:username/posts", UserController, :posts)
    post("/users/:username/penalties/:kind", UserController, :penalty)
    delete("/users/:username/penalties/:kind", UserController, :penalty)

    get("/notifications", NotificationController, :index)
    post("/notifications/read", NotificationController, :read_all)
    post("/notifications/:id/read", NotificationController, :read)

    get("/messages", MessageController, :index)
    post("/messages", MessageController, :create)
    get("/messages/:id", MessageController, :show)
    post("/messages/:id/replies", MessageController, :reply)

    get("/chat/channels", ChatController, :index)
    get("/chat/channels/browse", ChatController, :browse)
    get("/chat/channels/:id/messages", ChatController, :messages)
    post("/chat/channels/:id/messages", ChatController, :create)
    put("/chat/channels/:id/follow", ChatController, :follow)
    delete("/chat/channels/:id/follow", ChatController, :follow)
    patch("/chat/messages/:message_id", ChatController, :update)
    delete("/chat/messages/:message_id", ChatController, :delete)

    get("/groups", GroupController, :index)
    get("/groups/:name", GroupController, :show)
    get("/groups/:name/members", GroupController, :members)
    post("/groups/:name/join", GroupController, :join)
    delete("/groups/:name/membership", GroupController, :leave)

    get("/badges", Admin.BadgeController, :index)
    get("/search", SearchController, :index)
    post("/uploads", UploadController, :create)
    post("/preview", PreviewController, :create)

    get("/review", ReviewController, :index)
    post("/review/posts/:id/:decision", ReviewController, :decide)

    get("/admin/site-settings", Admin.SiteSettingController, :index)
    patch("/admin/site-settings", Admin.SiteSettingController, :update)
    get("/admin/webhooks", Admin.WebhookController, :index)
    post("/admin/webhooks", Admin.WebhookController, :create)
    get("/admin/webhooks/:id", Admin.WebhookController, :show)
    patch("/admin/webhooks/:id", Admin.WebhookController, :update)
    delete("/admin/webhooks/:id", Admin.WebhookController, :delete)
    post("/admin/badges", Admin.BadgeController, :create)
    patch("/admin/badges/:id", Admin.BadgeController, :update)
    delete("/admin/badges/:id", Admin.BadgeController, :delete)
    post("/admin/badges/:id/grants", Admin.BadgeController, :grant)
    delete("/admin/badges/grants/:grant_id", Admin.BadgeController, :revoke)

    match(:*, "/*path", DocsController, :not_found)
  end

  # The MCP server (see FireflyWeb.MCPController): API keys, no session.
  pipeline :mcp do
    plug(FireflyWeb.Plugs.ApiCurrentUser)
  end

  scope "/mcp", FireflyWeb do
    pipe_through(:mcp)

    post("/", MCPController, :post)
    get("/", MCPController, :unsupported)
    delete("/", MCPController, :unsupported)
  end

  # Inbound email webhooks
  scope "/inbound", FireflyWeb do
    pipe_through(:webhook)

    post("/sendgrid", InboundController, :sendgrid)
  end

  if Application.compile_env(:firefly_web, :dev_routes) do
    forward("/sent_emails", Bamboo.SentEmailViewerPlug)
  end

  # Last: an imported site's old URLs (see FireflyWeb.PermalinkController),
  # anything else a 404.
  scope "/", FireflyWeb do
    get("/*path", PermalinkController, :show)
  end
end
