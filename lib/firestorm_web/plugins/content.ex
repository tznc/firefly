defmodule FirestormWeb.Plugins.Content do
  @moduledoc """
  Plugins' content hooks: shortcodes and post-render transforms, applied to
  a post's HTML after `FirestormWeb.Markdown` renders and sanitizes it.

    * Shortcodes: `[name attr="value"]content[/name]` or `[name attr=value]`,
      for names a plugin declares in its manifest `shortcodes`; the first
      active plugin (in hook order) declaring a name owns it. Shortcodes in
      code blocks and inline code are left alone. Each plugin gets all of
      its shortcodes in a post in one `render_shortcodes` call; `content` is
      the HTML between the tags.
    * `render_post` hooks then run in order, each transforming the previous
      one's HTML.

  Whatever the plugins return goes through the same sanitizer allow-list
  as markdown, so a plugin can't add scripts, event handlers or iframes.
  A plugin that fails or takes longer than the time limit (`config
  :firestorm_web, FirestormWeb.Plugins.Content, timeout:`, 500 ms by
  default) is skipped: its step keeps the HTML it was given.

  Only posts anonymous visitors may read are transformed: plugins never see
  posts in private categories, or deleted, hidden or queued ones.

  Results are cached (on each node, least recently used out first), keyed
  by the HTML, the post and a fingerprint of the active content plugins
  (ids, versions, code, settings), so enabling, disabling, upgrading or
  reconfiguring a plugin makes the cache miss without explicit clearing.
  """

  alias FirestormWeb.{Forums, Plugin, Plugins}
  alias FirestormWeb.Forums.{Post, Thread}
  alias FirestormWeb.Plugin.Runner

  @cache :plugin_render_cache
  @hooks ["render_shortcodes", "render_post"]

  @doc "The render cache's name and size, for the supervisor."
  def cache_spec, do: %{id: @cache, start: {LruCache, :start_link, [@cache, 10_000]}}

  @doc """
  `html` (a post's rendered body) with the active plugins' shortcodes and
  transforms applied, sanitized. `post` must have its thread loaded or be
  given it.
  """
  @spec transform(String.t(), term, term) :: String.t()
  def transform(html, %Post{} = post, %Thread{} = thread) do
    case Enum.filter(Plugins.active(), fn plugin ->
           Enum.any?(@hooks, &Plugin.implements?(plugin, &1))
         end) do
      [] ->
        html

      plugins ->
        if public?(post, thread), do: cached(html, post, thread, plugins), else: html
    end
  end

  defp public?(post, thread),
    do: Post.readable_by?(post, nil) and Bodyguard.permit?(Forums, :view_thread, nil, thread)

  defp cached(html, post, thread, plugins) do
    key = {Plugins.fingerprint(plugins), post.id, :crypto.hash(:sha256, html)}

    case LruCache.get(@cache, key) do
      nil ->
        result = apply_plugins(html, context(post, thread), plugins)
        LruCache.put(@cache, key, result)
        result

      result ->
        result
    end
  end

  defp context(post, thread) do
    %{
      "id" => post.id,
      "thread_id" => thread.id,
      "category_id" => thread.category_id,
      "user_id" => post.user_id
    }
  end

  defp apply_plugins(html, context, plugins) do
    transformed =
      html
      |> shortcodes(context, plugins)
      |> render_posts(context, plugins)

    if transformed == html, do: html, else: sanitize(transformed)
  end

  # MDEx's spec types `:escape` as a list of atoms, but the function (and
  # its docs) take a keyword list, which is how content escaping is off.
  @dialyzer {:nowarn_function, sanitize: 1}

  @doc "Sanitizes HTML with the markdown renderer's allow-list."
  def sanitize(html) do
    MDEx.safe_html(html,
      sanitize: FirestormWeb.Markdown.sanitize_options(),
      escape: [content: false, curly_braces_in_code: false]
    )
  end

  defp render_posts(html, context, plugins) do
    Enum.reduce(plugins, html, fn plugin, html ->
      case run(plugin, "render_post", [%{"html" => html, "post" => context}]) do
        {:ok, new_html} when is_binary(new_html) -> new_html
        _failed_or_not_implemented -> html
      end
    end)
  end

  ## Shortcodes

  # Code is left alone: inline, or in blocks.
  @code ~r{(<pre[\s>].*?</pre>|<code[\s>].*?</code>)}s

  defp shortcodes(html, context, plugins) do
    owners = owners(plugins)
    parts = if owners == %{}, do: [], else: parse(html, pattern(Map.keys(owners)))

    case for {:shortcode, shortcode} <- parts, do: shortcode do
      [] ->
        html

      found ->
        rendered = render_shortcodes(found, owners, context, plugins)
        Enum.map_join(parts, &part(&1, rendered))
    end
  end

  # `[name attr="value" attr=value]content[/name]`, the closing tag optional.
  defp pattern(names) do
    names = Enum.map_join(names, "|", &Regex.escape/1)

    Regex.compile!(
      "\\[(#{names})((?:\\s+[a-z_]+=(?:\"[^\"]*\"|[^\\s\\]\"]+))*)\\s*\\](?:(.*?)\\[/\\1\\])?",
      "s"
    )
  end

  @doc "The shortcode names the active content plugins declare."
  def shortcode_names do
    for plugin <- Plugins.active(),
        Plugin.implements?(plugin, "render_shortcodes"),
        name <- plugin.manifest.shortcodes,
        do: name
  end

  # Shortcode name => the plugin that renders it: the first to declare it.
  defp owners(plugins) do
    for plugin <- Enum.reverse(plugins),
        Plugin.implements?(plugin, "render_shortcodes"),
        name <- plugin.manifest.shortcodes,
        into: %{},
        do: {name, plugin}
  end

  defp parse(html, pattern) do
    @code
    |> Regex.split(html, include_captures: true)
    |> Enum.flat_map(fn segment ->
      if Regex.match?(~r/\A<(pre|code)[\s>]/, segment),
        do: [{:text, segment}],
        else: parse_text(segment, pattern)
    end)
  end

  defp parse_text(text, pattern) do
    pattern
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn piece ->
      case Regex.run(pattern, piece) do
        [^piece, name, attrs | content] ->
          {:shortcode,
           %{raw: piece, name: name, attrs: attributes(attrs), content: List.first(content, "")}}

        _ ->
          {:text, piece}
      end
    end)
  end

  defp attributes(attrs) do
    for [_, key, value] <- Regex.scan(~r/([a-z_]+)=("[^"]*"|[^\s\]"]+)/, attrs), into: %{} do
      {key, String.trim(value, "\"")}
    end
  end

  # Raw shortcode text => its HTML, for those plugins rendered.
  defp render_shortcodes(found, owners, context, plugins) do
    by_plugin = Enum.group_by(found, &owners[&1.name].id)

    for plugin <- plugins, shortcodes = by_plugin[plugin.id], shortcodes != nil, reduce: %{} do
      rendered -> Map.merge(render_owned(plugin, shortcodes, context), rendered)
    end
  end

  defp render_owned(plugin, shortcodes, context) do
    input = %{
      "shortcodes" =>
        Enum.map(shortcodes, &%{"name" => &1.name, "attrs" => &1.attrs, "content" => &1.content}),
      "post" => context
    }

    case run(plugin, "render_shortcodes", [input]) do
      {:ok, results} when is_list(results) and length(results) == length(shortcodes) ->
        for {shortcode, result} <- Enum.zip(shortcodes, results),
            is_binary(result),
            into: %{},
            do: {shortcode.raw, result}

      _failed ->
        %{}
    end
  end

  defp part({:text, text}, _rendered), do: text
  defp part({:shortcode, %{raw: raw}}, rendered), do: Map.get(rendered, raw, raw)

  defp run(plugin, hook, args) do
    timeout = Application.get_env(:firestorm_web, __MODULE__, [])[:timeout] || 500
    Runner.invoke(plugin, hook, args, timeout: timeout)
  end
end
