defmodule FirestormWeb.LinkPreviews.Fetcher do
  @moduledoc """
  Fetches a page (or its preview image) for a link preview, guarded
  against server-side request forgery the way plugins' `http.fetch` is
  (see `FirestormWeb.Plugins.HTTP`): only http and https, every address
  the host resolves to must be public, and the request goes to the
  checked address. Redirects are followed by hand, at most
  5 hops, each new URL checked again. Connecting times out after 3
  seconds, each read after 5, the whole fetch after 10; bodies are capped
  (`:max_bytes`); only the content types asked for (`:types`) are kept.
  """

  alias FirestormWeb.Plugins.HTTP

  @max_redirects 5
  @deadline 10_000

  @doc """
  GETs `url`. Options: `:types` (accepted content types, e.g.
  `["text/html"]`) and `:max_bytes`. Returns `{:ok, %{url: final_url,
  content_type: type, body: body}}` or `{:error, reason}`.
  """
  def get(url, opts) when is_binary(url) do
    task = Task.async(fn -> follow(URI.parse(url), opts, 0) end)

    case Task.yield(task, @deadline) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timed_out -> {:error, :timeout}
    end
  end

  defp follow(_uri, _opts, hops) when hops > @max_redirects, do: {:error, :too_many_redirects}

  defp follow(%URI{scheme: scheme} = uri, opts, hops) when scheme in ["http", "https"] do
    with {:ok, ip} <- HTTP.resolve(uri.host),
         {:ok, status, headers, body} <- request(uri, ip, opts[:max_bytes]) do
      headers = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)

      cond do
        status in 300..399 and is_binary(headers["location"]) ->
          follow(URI.merge(uri, headers["location"]), opts, hops + 1)

        status in 200..299 ->
          accept(uri, headers["content-type"], body, opts[:types])

        true ->
          {:error, {:status, status}}
      end
    end
  end

  defp follow(_uri, _opts, _hops), do: {:error, :scheme}

  defp request(uri, ip, max_bytes) do
    host = if uri.port in [nil, 80, 443], do: uri.host, else: "#{uri.host}:#{uri.port}"

    headers = [
      {"host", host},
      {"user-agent", "Firefly link preview (+https://github.com/tznc/firefly)"},
      {"accept", "text/html,application/xhtml+xml,image/*;q=0.8"}
    ]

    options = [
      connect_timeout: 3_000,
      recv_timeout: 5_000,
      follow_redirect: false,
      pool: false,
      max_body_size: max_bytes,
      ssl_options: [server_name_indication: String.to_charlist(uri.host)]
    ]

    case :hackney.request(:get, HTTP.target(uri, ip), headers, "", options) do
      {:ok, status, headers, body} -> {:ok, status, headers, body}
      {:ok, status, headers} -> {:ok, status, headers, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp accept(uri, content_type, body, types) do
    type =
      content_type
      |> to_string()
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

    if type in types,
      do: {:ok, %{url: URI.to_string(uri), content_type: type, body: body}},
      else: {:error, {:content_type, type}}
  end
end
