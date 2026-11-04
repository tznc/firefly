defmodule FireflyWeb.Api.V1.OpenAPI do
  @moduledoc """
  The API's OpenAPI 3.1 document, served at `/api/v1/openapi.json` and
  rendered at `/api/v1/docs`.

  It's maintained by hand (`open_api_spex` only models OpenAPI 3.0): each
  operation is one entry of `operations/0`, and the schemas are JSON
  Schema (2020-12, the subset older validators read too). Tests check
  that every `/api/v1` route has an operation and back, and validate
  responses against these schemas, so they can't drift apart silently.
  """

  # {method, path, operation id, tag, summary, scope, opts}. `scope`: the
  # key scope it needs (`"read"` operations also work without a key, as a
  # visitor, unless `auth: true`). opts: `params` ({name, in, type,
  # description}), `body` (a request schema), `data` (the response's
  # `data` schema), `list` (a paginated list of that schema), `status`.
  @doc "Every operation: `{method, path, operation_id, tag, summary, scope, opts}`."
  def operations do
    [
      {:post, "/auth/identity", "login", "Authentication",
       "Trade a username and password (and a two-factor code) for a new full-scope API key", nil,
       body: %{
         type: "object",
         required: ["user"],
         properties: %{
           user: %{
             type: "object",
             required: ["username", "password"],
             properties: %{username: str(), password: str(), otp: str()}
           }
         }
       },
       data: %{type: "object", required: ["api_token"], properties: %{api_token: str()}}},
      {:get, "/me", "getMe", "Users", "The key's user, with the key's scopes", "read",
       auth: true, data: ref("Me")},
      {:patch, "/me", "updateMe", "Users", "Update your profile", "users:write",
       body: object(%{username: str(), name: str(), bio: str(), website: str(), location: str()}),
       data: ref("Me")},
      {:patch, "/me/preferences", "updatePreferences", "Users", "Update your preferences",
       "users:write", body: ref("Preferences"), data: ref("Me")},
      {:get, "/categories", "listCategories", "Categories", "Categories you may read", "read",
       list: ref("Category")},
      {:post, "/categories", "createCategory", "Categories", "Create a category (admins)",
       "admin", body: ref("CategoryInput"), data: ref("Category"), status: 201},
      {:get, "/categories/{id}", "getCategory", "Categories", "A category", "read",
       data: ref("Category")},
      {:patch, "/categories/{id}", "updateCategory", "Categories", "Edit a category (admins)",
       "admin", body: ref("CategoryInput"), data: ref("Category")},
      {:delete, "/categories/{id}", "deleteCategory", "Categories", "Delete a category (admins)",
       "admin", status: 204},
      {:get, "/categories/{id}/threads", "listCategoryThreads", "Categories",
       "A category's threads, pinned first, then by last activity", "read", list: ref("Thread")},
      {:put, "/categories/{id}/notification-level", "setCategoryLevel", "Categories",
       "Your notification level for a category", "users:write",
       body: ref("LevelInput"), data: ref("Level")},
      {:get, "/threads", "listThreads", "Threads", "A thread list: latest, new, unread or top",
       "read",
       params: [
         {"view", :query, enum(~w(latest new unread top)),
          "Which list (new and unread need a key)"},
         {"period", :query, enum(~w(day week month year all)), "For top: the period"}
       ],
       list: ref("Thread")},
      {:post, "/threads", "createThread", "Threads", "Start a thread", "topics:write",
       body: %{
         type: "object",
         required: ["category_id", "title", "body"],
         properties: %{
           category_id: int(),
           title: str(),
           body: str(),
           tags: %{
             type: ["array", "string"],
             items: str(),
             description: "Names, or comma-separated"
           }
         }
       },
       data: ref("Thread"),
       status: 201},
      {:get, "/threads/{id}", "getThread", "Threads", "A thread", "read", data: ref("Thread")},
      {:patch, "/threads/{id}", "updateThread", "Threads", "Rename or retag a thread",
       "topics:write",
       body: object(%{title: str(), tags: %{type: ["array", "string"], items: str()}}),
       data: ref("Thread")},
      {:delete, "/threads/{id}", "deleteThread", "Threads", "Delete a thread", "topics:write",
       status: 204},
      {:get, "/threads/{id}/posts", "listThreadPosts", "Threads",
       "A thread's posts, oldest first", "read", list: ref("Post")},
      {:post, "/threads/{id}/posts", "replyToThread", "Posts", "Reply to a thread",
       "topics:write", body: ref("BodyInput"), data: ref("Post"), status: 201},
      {:post, "/threads/{id}/read", "markThreadRead", "Threads",
       "Mark a thread read up to its newest post", "users:write", status: 204},
      {:put, "/threads/{id}/notification-level", "setThreadLevel", "Threads",
       "Your notification level for a thread", "users:write",
       body: ref("LevelInput"), data: ref("Level")},
      {:post, "/threads/{id}/move", "moveThread", "Threads", "Move a thread to another category",
       "topics:write", body: object(%{category_id: int()}, ["category_id"]), data: ref("Thread")},
      {:put, "/threads/{id}/solution", "acceptAnswer", "Threads",
       "Accept a reply as the answer (Q&A categories)", "topics:write",
       body: object(%{post_id: int()}, ["post_id"]), data: ref("Thread")},
      {:delete, "/threads/{id}/solution", "unacceptAnswer", "Threads", "Unaccept the answer",
       "topics:write", data: ref("Thread")},
      {:post, "/threads/{id}/{action}", "moderateThread", "Threads",
       "Pin, close or archive a thread (value: false undoes it)", "topics:write",
       params: [{"action", :path, enum(~w(pin close archive)), "The topic tool"}],
       body: object(%{value: bool()}),
       data: ref("Thread")},
      {:post, "/posts", "createPost", "Posts", "Reply to a thread (by thread_id)", "topics:write",
       body: %{
         type: "object",
         required: ["thread_id"],
         properties: %{thread_id: int(), body: str(), post: object(%{body: str()})}
       },
       data: ref("Post"),
       status: 201},
      {:get, "/posts/{id}", "getPost", "Posts", "A post", "read", data: ref("Post")},
      {:patch, "/posts/{id}", "updatePost", "Posts", "Edit a post", "topics:write",
       body: ref("BodyInput"), data: ref("Post")},
      {:delete, "/posts/{id}", "deletePost", "Posts", "Delete a post", "topics:write",
       status: 204},
      {:post, "/posts/{id}/restore", "restorePost", "Posts", "Restore a deleted post (admins)",
       "topics:write", data: ref("Post")},
      {:put, "/posts/{id}/like", "likePost", "Posts", "Like a post", "topics:write",
       data: ref("Post")},
      {:delete, "/posts/{id}/like", "unlikePost", "Posts", "Remove your like", "topics:write",
       data: ref("Post")},
      {:put, "/posts/{id}/bookmark", "bookmarkPost", "Posts",
       "Bookmark a post, with an optional note and reminder", "topics:write",
       body:
         object(%{
           note: str(),
           reminder: enum(["", "later_today", "tomorrow", "next_week", "custom"]),
           custom_at: %{type: "string", description: "For custom: a UTC date and time"}
         }),
       data: ref("Bookmark")},
      {:delete, "/posts/{id}/bookmark", "unbookmarkPost", "Posts", "Remove your bookmark",
       "topics:write", status: 204},
      {:post, "/posts/{id}/flags", "flagPost", "Posts", "Flag a post for staff", "topics:write",
       body: object(%{reason: str(), note: str()}, ["reason"]),
       data: object(%{id: int(), post_id: int(), reason: str()}),
       status: 201},
      {:put, "/posts/{id}/wiki", "setWiki", "Posts",
       "Make a post a wiki or not (leaders, admins)", "topics:write",
       body: object(%{wiki: bool()}), data: ref("Post")},
      {:get, "/posts/{id}/poll", "getPoll", "Polls", "A post's poll", "read", data: ref("Poll")},
      {:post, "/posts/{id}/poll/vote", "votePoll", "Polls",
       "Vote: option (single), options (multiple) or ranks (ranked)", "topics:write",
       body:
         object(%{
           option: int(),
           options: %{type: "array", items: int()},
           ranks: %{type: "object", additionalProperties: int()}
         }),
       data: ref("Poll")},
      {:post, "/posts/{id}/poll/{action}", "closePoll", "Polls",
       "Close or reopen a poll (its author, admins)", "topics:write",
       params: [{"action", :path, enum(~w(close reopen)), "What to do"}], data: ref("Poll")},
      {:get, "/bookmarks", "listBookmarks", "Posts", "Your bookmarks", "read",
       auth: true, list: ref("BookmarkListed")},
      {:get, "/tags", "listTags", "Tags", "Tags in use, most used first", "read",
       list: ref("Tag")},
      {:get, "/tags/{name}/threads", "listTagThreads", "Tags", "A tag's threads", "read",
       list: ref("Thread")},
      {:put, "/tags/{name}/notification-level", "setTagLevel", "Tags",
       "Your notification level for a tag", "users:write",
       body: ref("LevelInput"), data: ref("Level")},
      {:get, "/users", "listUsers", "Users", "The users directory", "read",
       params: [
         {"period", :query, enum(~w(all year month week day)), "Stats period"},
         {"order", :query, str(), "A stat to order by"},
         {"asc", :query, enum(["true", "false"]), "Ascending"},
         {"name", :query, str(), "Search usernames and names"}
       ],
       list: ref("DirectoryEntry")},
      {:get, "/users/{username}", "getUser", "Users", "A profile", "read", data: ref("Profile")},
      {:get, "/users/{username}/posts", "listUserPosts", "Users", "A member's activity", "read",
       params: [
         {"filter", :query, enum(~w(all topics replies solved likes)), "Which activity"}
       ],
       list: ref("Post")},
      {:post, "/users/{username}/penalties/{kind}", "penalizeUser", "Moderation",
       "Silence or suspend a member (admins)", "admin",
       params: [{"kind", :path, enum(~w(silence suspend)), "The penalty"}],
       body: object(%{duration: str(), until: str(), reason: str()}, ["reason"]),
       data: ref("Penalized")},
      {:delete, "/users/{username}/penalties/{kind}", "liftPenalty", "Moderation",
       "Lift a silence or suspension (admins)", "admin",
       params: [{"kind", :path, enum(~w(silence suspend)), "The penalty"}], data: ref("Penalized")},
      {:get, "/notifications", "listNotifications", "Notifications",
       "Your latest notifications (X-Unread-Count: how many are unread)", "read",
       auth: true, list: ref("Notification")},
      {:post, "/notifications/read", "readAllNotifications", "Notifications",
       "Mark every notification read", "notifications:write", status: 204},
      {:post, "/notifications/{id}/read", "readNotification", "Notifications",
       "Mark a notification read", "notifications:write", data: ref("Notification")},
      {:get, "/messages", "listConversations", "Messages", "Your private conversations", "read",
       auth: true, list: ref("Conversation")},
      {:post, "/messages", "startConversation", "Messages", "Start a private conversation",
       "messages:write",
       body: %{
         type: "object",
         required: ["title", "body", "recipients"],
         properties: %{
           title: str(),
           body: str(),
           recipients: %{
             type: ["array", "string"],
             items: str(),
             description: "Usernames, or a group's name"
           }
         }
       },
       data: object(%{id: int(), title: str()}),
       status: 201},
      {:get, "/messages/{id}", "getConversation", "Messages",
       "A conversation and its messages (marks it read)", "read",
       auth: true, data: ref("ConversationWithMessages")},
      {:post, "/messages/{id}/replies", "replyToConversation", "Messages", "Reply",
       "messages:write", body: ref("BodyInput"), data: ref("ConversationMessage"), status: 201},
      {:get, "/chat/channels", "listChatChannels", "Chat",
       "Your chat channels and direct messages, with unread counts", "read",
       auth: true, data: %{type: "array", items: ref("ChatChannel")}},
      {:get, "/chat/channels/browse", "browseChatChannels", "Chat",
       "Category channels you may join", "read",
       auth: true, data: %{type: "array", items: ref("ChatChannel")}},
      {:get, "/chat/channels/{id}/messages", "listChatMessages", "Chat",
       "A channel's messages, oldest first; the cursor goes back in time", "read",
       auth: true, list: ref("ChatMessage")},
      {:post, "/chat/channels/{id}/messages", "sendChatMessage", "Chat", "Send a message",
       "chat:write",
       body: object(%{body: str(), in_reply_to_id: int(), thread_of: int()}, ["body"]),
       data: ref("ChatMessage"),
       status: 201},
      {:put, "/chat/channels/{id}/follow", "followChatChannel", "Chat", "Follow a channel",
       "chat:write", status: 204},
      {:delete, "/chat/channels/{id}/follow", "unfollowChatChannel", "Chat", "Leave a channel",
       "chat:write", status: 204},
      {:patch, "/chat/messages/{message_id}", "editChatMessage", "Chat", "Edit your message",
       "chat:write", body: ref("BodyInput"), data: ref("ChatMessage")},
      {:delete, "/chat/messages/{message_id}", "deleteChatMessage", "Chat", "Delete a message",
       "chat:write", status: 204},
      {:get, "/groups", "listGroups", "Groups", "Groups you may see", "read", list: ref("Group")},
      {:get, "/groups/{name}", "getGroup", "Groups", "A group", "read", data: ref("Group")},
      {:get, "/groups/{name}/members", "listGroupMembers", "Groups", "A group's members", "read",
       list: ref("GroupMember")},
      {:post, "/groups/{name}/join", "joinGroup", "Groups",
       "Join an open group, or ask to join (message)", "users:write",
       body: object(%{message: str()}), data: object(%{status: enum(~w(joined requested))})},
      {:delete, "/groups/{name}/membership", "leaveGroup", "Groups", "Leave a group",
       "users:write", status: 204},
      {:get, "/badges", "listBadges", "Badges", "The badges members can earn", "read",
       list: ref("Badge")},
      {:get, "/search", "search", "Search", "Search posts (the search page's syntax)", "read",
       params: [
         {"q", :query, str(), "Terms and inline filters"},
         {"category", :query, str(), "A category slug"},
         {"tag", :query, str(), "A tag"},
         {"user", :query, str(), "A username"},
         {"in", :query, str(), "likes, bookmarks, posted, ..."},
         {"order", :query, enum(~w(relevance latest likes)), "Order"},
         {"page", :query, int(), "Page number"}
       ],
       response: ref("SearchResults")},
      {:post, "/uploads", "upload", "Uploads", "Upload a file (multipart, field file)",
       "uploads:write",
       content: "multipart/form-data",
       body: %{
         type: "object",
         required: ["file"],
         properties: %{file: %{type: "string", contentMediaType: "application/octet-stream"}}
       },
       data: ref("Upload"),
       status: 201},
      {:post, "/preview", "preview", "Posts", "Render a post body as the composer previews it",
       "read",
       body: object(%{body: str(), post: object(%{body: str()})}),
       data: object(%{html: str()}),
       status: 201},
      {:get, "/review", "listReviewQueue", "Moderation",
       "The review queue: flagged and queued posts (admins)", "admin", list: ref("ReviewItem")},
      {:post, "/review/posts/{id}/{decision}", "reviewPost", "Moderation",
       "Decide a flagged or queued post (admins)", "admin",
       params: [
         {"decision", :path, enum(~w(agree disagree defer approve reject)), "The decision"}
       ],
       body: object(%{action: enum(~w(hide delete)), reason: str()}),
       status: 204},
      {:get, "/admin/site-settings", "listSiteSettings", "Admin", "Every site setting", "admin",
       data: %{type: "array", items: ref("SiteSetting")}},
      {:patch, "/admin/site-settings", "updateSiteSettings", "Admin",
       "Save settings: an object of key to value", "admin",
       body: %{type: "object", additionalProperties: true},
       data: %{type: "array", items: ref("SiteSetting")}},
      {:get, "/admin/webhooks", "listWebhooks", "Admin", "Outbound webhooks", "admin",
       list: ref("Webhook")},
      {:post, "/admin/webhooks", "createWebhook", "Admin", "Add a webhook", "admin",
       body: ref("WebhookInput"), data: ref("Webhook"), status: 201},
      {:get, "/admin/webhooks/{id}", "getWebhook", "Admin", "A webhook", "admin",
       data: ref("Webhook")},
      {:patch, "/admin/webhooks/{id}", "updateWebhook", "Admin", "Edit a webhook", "admin",
       body: ref("WebhookInput"), data: ref("Webhook")},
      {:delete, "/admin/webhooks/{id}", "deleteWebhook", "Admin", "Delete a webhook", "admin",
       status: 204},
      {:post, "/admin/badges", "createBadge", "Admin", "Create a badge", "admin",
       body: ref("BadgeInput"), data: ref("Badge"), status: 201},
      {:patch, "/admin/badges/{id}", "updateBadge", "Admin", "Edit a badge", "admin",
       body: ref("BadgeInput"), data: ref("Badge")},
      {:delete, "/admin/badges/{id}", "deleteBadge", "Admin", "Delete a badge", "admin",
       status: 204},
      {:post, "/admin/badges/{id}/grants", "grantBadge", "Admin", "Grant a badge to a member",
       "admin",
       body: object(%{username: str(), reason: str()}, ["username"]),
       data: object(%{id: int(), badge_id: int(), user_id: int()}),
       status: 201},
      {:delete, "/admin/badges/grants/{grant_id}", "revokeBadge", "Admin", "Revoke a grant",
       "admin", status: 204}
    ]
  end

  @doc "The OpenAPI document (a map ready for JSON)."
  def spec do
    %{
      openapi: "3.1.0",
      info: %{
        title: "#{Firefly.SiteSettings.get("title")} API",
        version: "1",
        description: description()
      },
      servers: [%{url: FireflyWeb.Endpoint.url() <> "/api/v1"}],
      tags:
        for(
          tag <- Enum.uniq(Enum.map(operations(), &elem(&1, 3))),
          do: %{name: tag}
        ),
      paths: paths(),
      components: %{
        securitySchemes: %{
          apiKey: %{
            type: "http",
            scheme: "bearer",
            description:
              "An API key (Settings > API keys, or /staff/api-keys for global keys). A global key acts as the user in the Api-Username header."
          }
        },
        parameters: %{
          limit: %{
            name: "limit",
            in: "query",
            schema: %{type: "integer", minimum: 1, maximum: 100, default: 30}
          },
          cursor: %{
            name: "cursor",
            in: "query",
            description: "The previous page's meta.next_cursor",
            schema: str()
          }
        },
        schemas: schemas()
      }
    }
  end

  defp description do
    """
    The forum's REST API. Every request may carry an API key
    (`Authorization: Bearer <key>`); without one it reads as a visitor.
    A key acts as its user, with that user's permissions, limited to the
    key's scopes: `read`, `write` (every `*:write`), `topics:write`,
    `messages:write`, `chat:write`, `uploads:write`, `users:write`,
    `notifications:write` and `admin`.

    Lists are paginated: `limit` (up to 100) and `cursor` (from
    `meta.next_cursor`, null on the last page). Errors are
    `application/problem+json` (RFC 9457): `type`, `title`, `status`,
    `detail`, and `errors` by field for invalid input. Each key has a
    rate limit (`429`, with `Retry-After`).

    ## Problems {#problems}

    <a id="problem-bad-request"></a><a id="problem-unauthorized"></a><a id="problem-forbidden"></a>
    <a id="problem-not-found"></a><a id="problem-conflict"></a><a id="problem-unprocessable-content"></a>
    <a id="problem-too-many-requests"></a><a id="problem-service-unavailable"></a>
    `400` a bad cursor; `401` no key, or an invalid, revoked or expired one;
    `403` the key lacks the scope, or the user the permission; `404` not
    found, or not visible to the user; `409` the resource changed
    meanwhile; `422` invalid input; `429` a rate limit; `503` the site is
    read-only for maintenance.
    """
  end

  defp paths do
    operations()
    |> Enum.group_by(&elem(&1, 1))
    |> Map.new(fn {path, operations} ->
      {path, Map.new(operations, &{elem(&1, 0), operation(&1)})}
    end)
  end

  defp operation({_method, path, id, tag, summary, scope, opts}) do
    path_params =
      for [_, name] <- Regex.scan(~r/\{(\w+)\}/, path),
          not Enum.any?(opts[:params] || [], &(elem(&1, 0) == name)) do
        {name, :path, if(name in ~w(name username), do: str(), else: int()), nil}
      end

    params =
      Enum.map(path_params ++ (opts[:params] || []), fn {name, location, schema, description} ->
        %{name: name, in: location, required: location == :path, schema: schema}
        |> put_if(:description, description)
      end)

    params =
      if opts[:list],
        do:
          params ++
            [
              %{"$ref": "#/components/parameters/limit"},
              %{"$ref": "#/components/parameters/cursor"}
            ],
        else: params

    %{
      operationId: id,
      tags: [tag],
      summary: summary,
      description: scope_text(scope, opts),
      parameters: params,
      security: security(scope, opts),
      responses: responses(opts)
    }
    |> put_if(:requestBody, request_body(opts))
    |> Map.put(:"x-scope", scope)
  end

  defp scope_text(nil, _opts), do: "No key needed."

  defp scope_text("read", opts),
    do:
      if(opts[:auth],
        do: "Scope: `read` (a key is required).",
        else: "Scope: `read` (or no key, as a visitor)."
      )

  defp scope_text(scope, _opts), do: "Scope: `#{scope}`."

  defp security(nil, _opts), do: [%{}]

  defp security("read", opts),
    do: if(opts[:auth], do: [%{apiKey: []}], else: [%{}, %{apiKey: []}])

  defp security(_scope, _opts), do: [%{apiKey: []}]

  defp request_body(opts) do
    if body = opts[:body] do
      %{required: true, content: %{(opts[:content] || "application/json") => %{schema: body}}}
    end
  end

  defp responses(opts) do
    status = to_string(opts[:status] || 200)

    success =
      cond do
        opts[:status] == 204 ->
          %{description: "Done"}

        opts[:list] ->
          json_response(%{
            type: "object",
            required: ["data", "meta"],
            properties: %{data: %{type: "array", items: opts[:list]}, meta: ref("Meta")}
          })

        opts[:data] ->
          json_response(%{type: "object", required: ["data"], properties: %{data: opts[:data]}})

        opts[:response] ->
          json_response(opts[:response])
      end

    problem = %{
      description: "A problem",
      content: %{"application/problem+json" => %{schema: ref("Problem")}}
    }

    %{status => success, "4XX" => problem}
  end

  defp json_response(schema),
    do: %{description: "OK", content: %{"application/json" => %{schema: schema}}}

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  @doc "The component schemas, by name."
  def schemas do
    %{
      "Problem" =>
        object(
          %{
            type: str(),
            title: str(),
            status: int(),
            detail: str(),
            errors: %{type: "object", additionalProperties: %{type: "array", items: str()}}
          },
          ~w(type title status detail)
        ),
      "Meta" => object(%{limit: int(), next_cursor: nullable(str())}, ~w(limit next_cursor)),
      "User" =>
        object(
          %{
            id: int(),
            username: str(),
            name: nullable(str()),
            avatar_url: nullable(str()),
            inserted_at: str(),
            updated_at: str()
          },
          ~w(id username)
        ),
      "Profile" =>
        all_of("User", %{
          bio: nullable(str()),
          website: nullable(str()),
          location: nullable(str()),
          trust_level: int(),
          url: str()
        }),
      "Me" =>
        all_of("Profile", %{
          email: nullable(str()),
          preferences: ref("Preferences"),
          api_key:
            object(%{
              name: str(),
              scopes: %{type: "array", items: str()},
              expires_at: nullable(str()),
              global: bool()
            })
        }),
      "Preferences" =>
        object(%{
          email_notifications: bool(),
          allow_private_messages: bool(),
          theme: enum(~w(system light dark)),
          reply_level: str(),
          new_thread_level: str(),
          hide_profile_activity: bool(),
          hide_from_directory: bool(),
          hide_profile: bool(),
          digest_frequency: nullable(str()),
          push_only_when_away: bool(),
          mailing_list_mode: bool(),
          mailing_list_no_echo: bool()
        }),
      "DirectoryEntry" =>
        all_of("User", %{stats: %{type: "object", additionalProperties: int()}}),
      "Penalized" =>
        all_of("User", %{
          silenced_until: nullable(str()),
          silence_reason: nullable(str()),
          suspended_until: nullable(str()),
          suspend_reason: nullable(str())
        }),
      "Category" =>
        object(
          %{
            id: int(),
            title: str(),
            slug: str(),
            description: nullable(str()),
            color: nullable(str()),
            position: int(),
            parent_id: nullable(int()),
            allow_accepted_answers: bool(),
            restricted: bool(),
            url: str()
          },
          ~w(id title slug)
        ),
      "CategoryInput" =>
        object(%{
          title: str(),
          description: str(),
          color: str(),
          position: int(),
          parent_id: nullable(int()),
          allow_accepted_answers: bool()
        }),
      "Thread" =>
        object(
          %{
            id: int(),
            title: str(),
            slug: str(),
            category_id: int(),
            pinned: bool(),
            closed: bool(),
            archived: bool(),
            views: int(),
            accepted_post_id: nullable(int()),
            merged_into_id: nullable(int()),
            posts_count: nullable(int()),
            last_post_at: nullable(str()),
            unread_count: nullable(int()),
            new: nullable(bool()),
            tags: nullable(%{type: "array", items: str()}),
            user: nullable(ref("User")),
            url: str()
          },
          ~w(id title category_id pinned closed archived url)
        ),
      "Post" =>
        object(
          %{
            id: int(),
            thread_id: int(),
            body: str(),
            body_html: str(),
            deleted: bool(),
            hidden: bool(),
            queued: bool(),
            wiki: bool(),
            edited_at: nullable(str()),
            user_id: nullable(int()),
            user: nullable(ref("User")),
            like_count: int(),
            liked: bool(),
            bookmarked: bool(),
            thread_title: str()
          },
          ~w(id thread_id body body_html deleted hidden queued)
        ),
      "BodyInput" => object(%{body: str()}, ["body"]),
      "Bookmark" =>
        object(%{id: int(), post_id: int(), note: nullable(str()), remind_at: nullable(str())}),
      "BookmarkListed" =>
        object(%{
          id: int(),
          post_id: int(),
          thread_id: int(),
          thread_title: str(),
          note: nullable(str()),
          remind_at: nullable(str())
        }),
      "Poll" =>
        object(
          %{
            kind: enum(~w(single multiple ranked)),
            min_choices: nullable(int()),
            max_choices: nullable(int()),
            public: bool(),
            closed: bool(),
            close_at: nullable(str()),
            options: %{type: "array", items: object(%{id: int(), text: str()})},
            mine: %{type: "array", items: int()},
            voters: int(),
            results: nullable(object(%{counts: %{type: "object", additionalProperties: int()}}))
          },
          ~w(kind options voters)
        ),
      "Tag" => object(%{name: str(), threads_count: int()}, ["name"]),
      "Level" => object(%{level: ref("LevelName")}, ["level"]),
      "LevelInput" => object(%{level: ref("LevelName")}, ["level"]),
      "LevelName" => enum(~w(watching tracking normal muted)),
      "Notification" =>
        object(
          %{
            id: int(),
            kind: str(),
            subject: nullable(str()),
            body: nullable(str()),
            url: nullable(str()),
            thread_id: nullable(int()),
            post_id: nullable(int()),
            conversation_id: nullable(int()),
            read: bool()
          },
          ~w(id kind read)
        ),
      "Conversation" =>
        object(
          %{
            id: int(),
            title: str(),
            last_message_at: nullable(str()),
            unread_count: int(),
            participants: %{type: "array", items: ref("User")}
          },
          ~w(id title participants)
        ),
      "ConversationMessage" =>
        object(
          %{id: int(), body: str(), body_html: str(), user: ref("User"), inserted_at: str()},
          ~w(id body user)
        ),
      "ConversationWithMessages" =>
        all_of("Conversation", %{messages: %{type: "array", items: ref("ConversationMessage")}}),
      "ChatChannel" =>
        object(
          %{
            id: int(),
            kind: enum(~w(category direct)),
            title: str(),
            slug: nullable(str()),
            description: nullable(str()),
            status: str(),
            category_id: nullable(int()),
            unread: int(),
            mentions: int(),
            muted: bool(),
            following: bool()
          },
          ~w(id kind title)
        ),
      "ChatMessage" =>
        object(
          %{
            id: int(),
            channel_id: int(),
            body: str(),
            body_html: str(),
            user: nullable(ref("User")),
            thread_id: nullable(int()),
            in_reply_to_id: nullable(int()),
            reply_count: int(),
            deleted: bool(),
            edited_at: nullable(str()),
            inserted_at: str()
          },
          ~w(id channel_id body deleted)
        ),
      "Group" =>
        object(
          %{
            id: int(),
            name: str(),
            description: nullable(str()),
            visibility: str(),
            membership: str(),
            mentionable: str(),
            messageable: str(),
            members_count: int()
          },
          ~w(id name)
        ),
      "GroupMember" => all_of("User", %{owner: bool()}),
      "Badge" =>
        object(
          %{
            id: int(),
            name: str(),
            description: str(),
            icon: str(),
            badge_type: enum(~w(gold silver bronze)),
            grouping: str(),
            enabled: bool(),
            allow_title: bool(),
            multiple_grant: bool(),
            listable: bool(),
            system: bool(),
            grant_count: int()
          },
          ~w(id name)
        ),
      "BadgeInput" =>
        object(%{
          name: str(),
          description: str(),
          icon: str(),
          badge_type: enum(~w(gold silver bronze)),
          grouping: str(),
          enabled: bool(),
          allow_title: bool(),
          multiple_grant: bool(),
          listable: bool()
        }),
      "Webhook" =>
        object(
          %{
            id: int(),
            payload_url: str(),
            content_type: str(),
            wildcard: bool(),
            event_types: %{type: "array", items: str()},
            category_ids: %{type: "array", items: int()},
            tag_names: %{type: "array", items: str()},
            group_ids: %{type: "array", items: int()},
            active: bool(),
            failure_count: int(),
            last_status: nullable(str()),
            last_delivery_at: nullable(str())
          },
          ~w(id payload_url active)
        ),
      "WebhookInput" =>
        object(%{
          payload_url: str(),
          secret: str(),
          wildcard: bool(),
          event_types: %{type: "array", items: str()},
          category_ids: %{type: "array", items: int()},
          tag_names: %{type: "array", items: str()},
          group_ids: %{type: "array", items: int()},
          active: bool()
        }),
      "SiteSetting" =>
        object(
          %{
            key: str(),
            section: str(),
            type: enum(~w(string text email boolean integer select)),
            label: str(),
            value: %{},
            default: %{}
          },
          ~w(key section type value)
        ),
      "ReviewItem" =>
        object(
          %{
            kind: enum(~w(flagged queued)),
            post: ref("Post"),
            thread_id: int(),
            thread_title: str(),
            flags: %{
              type: "array",
              items: object(%{reason: str(), note: nullable(str()), user_id: nullable(int())})
            }
          },
          ~w(kind post)
        ),
      "SearchResults" =>
        object(
          %{
            results: %{
              type: "array",
              items:
                object(%{
                  post_id: int(),
                  thread_id: int(),
                  thread_title: str(),
                  category_id: int(),
                  username: str(),
                  url: str(),
                  headline_html: str()
                })
            },
            page: int(),
            total_pages: int(),
            total_entries: int()
          },
          ~w(results page total_pages)
        ),
      "Upload" =>
        object(%{url: str(), markdown: str(), content_type: str(), size: int()}, ~w(url markdown))
    }
  end

  defp str, do: %{type: "string"}
  defp int, do: %{type: "integer"}
  defp bool, do: %{type: "boolean"}
  defp enum(values), do: %{type: "string", enum: values}
  defp ref(name), do: %{"$ref": "#/components/schemas/#{name}"}

  # OpenAPI 3.1 (JSON Schema): nullable is a type union.
  defp nullable(%{"$ref": _} = schema), do: %{anyOf: [schema, %{type: "null"}]}
  defp nullable(%{type: type} = schema), do: %{schema | type: [type, "null"]}

  defp object(properties, required \\ []),
    do:
      put_if(
        %{type: "object", properties: properties},
        :required,
        if(required != [], do: required)
      )

  defp all_of(base, properties), do: %{allOf: [ref(base), object(properties)]}
end
