defmodule Firefly.AI.MCP do
  @moduledoc """
  A read-only [Model Context Protocol](https://modelcontextprotocol.io)
  server: the JSON-RPC 2.0 messages the web interface receives at `/mcp`
  (Streamable HTTP; see `FireflyWeb.MCPController`), handled for the member
  whose API token authenticated the request. Off unless the
  `mcp_enabled` site setting is on.

  It answers `initialize` (negotiating the protocol version), `ping`,
  `tools/list` and `tools/call`, and accepts notifications (such as
  `notifications/initialized`). The tools, all read-only and all filtered
  by what that member may read (the same rules as the site, through
  `Firefly.Discussion.Search` and the `:view_thread` policy):

    * `search` - posts matching a query (with search's inline filters;
      hybrid when semantic search is on)
    * `read_topic` - a topic and its posts, a page at a time
    * `list_latest` - the most recently active topics
    * `get_user_profile` - a member's public profile and stats

  Private messages and chat aren't exposed.
  """

  alias Firefly.{Accounts, Discussion, Repo, URLs}
  alias Firefly.Accounts.{Profiles, User}
  alias Firefly.AI.SemanticSearch
  alias Firefly.Discussion.{Post, Search, Thread}

  @versions ["2025-06-18", "2025-03-26", "2024-11-05"]
  @posts_per_page 50

  @doc "The protocol versions this server speaks, newest first."
  def versions, do: @versions

  @doc """
  Handles one decoded JSON-RPC message from `user`: `{:reply, response}`
  for a request, or `:noreply` for a notification or a response.
  """
  @spec handle(term, struct) :: {:reply, map} | :noreply
  def handle(%{"jsonrpc" => "2.0", "method" => method, "id" => id} = request, %User{} = user)
      when is_binary(method) and (is_binary(id) or is_integer(id)) do
    {:reply,
     case call(method, request["params"] || %{}, user) do
       {:ok, result} -> %{jsonrpc: "2.0", id: id, result: result}
       {:error, code, message} -> error(id, code, message)
     end}
  end

  def handle(%{"jsonrpc" => "2.0", "method" => method} = notification, _user)
      when is_binary(method) and not is_map_key(notification, "id"),
      do: :noreply

  def handle(%{"jsonrpc" => "2.0", "id" => _id} = response, _user)
      when is_map_key(response, "result") or is_map_key(response, "error"),
      do: :noreply

  def handle(message, _user) do
    id = if is_map(message), do: message["id"]
    {:reply, error(if(is_binary(id) or is_integer(id), do: id), -32_600, "Invalid request")}
  end

  @doc "A JSON-RPC error response."
  def error(id, code, message),
    do: %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}

  defp call("initialize", params, _user) do
    requested = params["protocolVersion"]

    {:ok,
     %{
       protocolVersion: if(requested in @versions, do: requested, else: hd(@versions)),
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{
         name: "firefly",
         title: Firefly.SiteSettings.get("title"),
         version: to_string(Application.spec(:firefly, :vsn))
       },
       instructions:
         "Read-only access to the forum #{Firefly.SiteSettings.get("title")}, as the member whose token you use: search posts, read topics, list the latest topics and look up members."
     }}
  end

  defp call("ping", _params, _user), do: {:ok, %{}}
  defp call("tools/list", _params, _user), do: {:ok, %{tools: tools()}}

  defp call("tools/call", %{"name" => name} = params, user) when is_binary(name) do
    arguments = params["arguments"] || %{}

    if Enum.any?(tools(), &(&1.name == name)) and is_map(arguments) do
      {:ok, tool_result(tool(name, arguments, user))}
    else
      {:error, -32_602, "Unknown tool or invalid arguments: #{name}"}
    end
  end

  defp call("tools/call", _params, _user), do: {:error, -32_602, "A tool name is required"}
  defp call(method, _params, _user), do: {:error, -32_601, "Method not found: #{method}"}

  defp tool_result({:ok, data}),
    do: %{
      content: [%{type: "text", text: Jason.encode!(data)}],
      structuredContent: data,
      isError: false
    }

  defp tool_result({:error, message}),
    do: %{content: [%{type: "text", text: message}], isError: true}

  @doc "The tools, as `tools/list` describes them."
  def tools do
    read_only = %{readOnlyHint: true, openWorldHint: false}

    [
      %{
        name: "search",
        title: "Search the forum",
        description:
          "Searches posts. The query may use filters: category:slug, tag:name, @username, in:title, order:latest, status:solved or status:unsolved.",
        inputSchema: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "What to search for"},
            page: %{type: "integer", minimum: 1, description: "Page of 20 results (default 1)"}
          },
          required: ["query"]
        },
        annotations: read_only
      },
      %{
        name: "read_topic",
        title: "Read a topic",
        description:
          "A topic (thread) and its posts, #{@posts_per_page} posts a page, in Markdown.",
        inputSchema: %{
          type: "object",
          properties: %{
            topic_id: %{type: "integer", description: "The topic's id"},
            page: %{type: "integer", minimum: 1, description: "Page of posts (default 1)"}
          },
          required: ["topic_id"]
        },
        annotations: read_only
      },
      %{
        name: "list_latest",
        title: "List the latest topics",
        description: "The most recently active topics.",
        inputSchema: %{
          type: "object",
          properties: %{
            limit: %{
              type: "integer",
              minimum: 1,
              maximum: 50,
              description: "How many (default 20)"
            }
          }
        },
        annotations: read_only
      },
      %{
        name: "get_user_profile",
        title: "Look up a member",
        description: "A member's public profile and stats, by username.",
        inputSchema: %{
          type: "object",
          properties: %{username: %{type: "string"}},
          required: ["username"]
        },
        annotations: read_only
      }
    ]
  end

  defp tool("search", %{"query" => query} = args, user) when is_binary(query) do
    search = Search.parse(String.slice(query, 0, 500))
    page = positive(args["page"], 1)

    results =
      if SemanticSearch.enabled?(),
        do: elem(SemanticSearch.run(search, user, page), 1),
        else: Search.run(search, user, page)

    {:ok,
     %{
       page: results.page_number,
       total_pages: results.total_pages,
       results:
         for %{post: post, thread: thread, headline: headline} <- results.entries do
           %{
             topic_id: thread.id,
             topic_title: thread.title,
             category: thread.category.title,
             post_id: post.id,
             author: post.user.username,
             excerpt: strip_marks(headline),
             created_at: post.inserted_at,
             url: post_url(thread, post)
           }
         end
     }}
  end

  defp tool("read_topic", %{"topic_id" => id} = args, user) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Thread{merged_into_id: nil} = thread <- Discussion.get_thread(id),
         true <- Bodyguard.permit?(Discussion, :view_thread, user, thread) do
      thread = Repo.preload(thread, [:category, :tags, posts: :user])
      posts = Enum.filter(thread.posts, &(not Post.deleted?(&1) and Post.readable_by?(&1, user)))
      page = positive(args["page"], 1)

      {:ok,
       %{
         topic_id: thread.id,
         title: thread.title,
         category: thread.category.title,
         tags: Enum.map(thread.tags, & &1.name),
         url: URLs.thread_url(thread),
         closed: Thread.closed?(thread),
         page: page,
         total_pages: max(div(length(posts) + @posts_per_page - 1, @posts_per_page), 1),
         posts:
           for post <-
                 posts |> Enum.drop((page - 1) * @posts_per_page) |> Enum.take(@posts_per_page) do
             %{
               post_id: post.id,
               author: post.user && post.user.username,
               body: post.body,
               created_at: post.inserted_at,
               edited_at: post.edited_at
             }
           end
       }}
    else
      _missing_or_hidden -> {:error, "No topic #{id} you can read."}
    end
  end

  defp tool("list_latest", args, user) do
    limit = args["limit"] |> positive(20) |> min(50)

    {:ok,
     %{
       topics:
         for thread <- Discussion.latest_threads(user, limit) do
           %{
             topic_id: thread.id,
             title: thread.title,
             category: thread.category.title,
             posts: thread.posts_count,
             last_post_at: thread.last_post_at,
             url: URLs.thread_url(thread)
           }
         end
     }}
  end

  defp tool("get_user_profile", %{"username" => username}, user) when is_binary(username) do
    case Accounts.get_user_by_username(username) do
      %User{deleted_at: nil} = member -> {:ok, profile(member, user)}
      _missing -> {:error, "No member @#{username}."}
    end
  end

  defp tool(name, _args, _user), do: {:error, "Invalid arguments for #{name}."}

  # Hidden profiles show only the username, as on the site.
  defp profile(member, viewer) do
    base = %{username: member.username, url: URLs.user_url(member)}

    if Profiles.visible?(member, viewer) do
      stats = Profiles.stats(member)

      Map.merge(base, %{
        name: member.name,
        bio: member.bio,
        location: member.location,
        website: member.website,
        trust_level: member.trust_level,
        joined_at: member.inserted_at,
        stats: %{
          topics: stats.topic_count,
          posts: stats.post_count,
          likes_received: stats.likes_received,
          days_visited: stats.days_visited
        }
      })
    else
      base
    end
  end

  defp positive(value, default) do
    case Integer.parse(to_string(value || "")) do
      {n, ""} when n > 0 -> n
      _ -> default
    end
  end

  defp strip_marks(headline), do: String.replace(headline, ~r{</?mark>}, "")

  defp post_url(thread, post), do: URLs.thread_url(thread) <> "#post-#{post.id}"
end
