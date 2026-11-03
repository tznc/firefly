defmodule Firefly.Plugins.Egress do
  @moduledoc """
  The plugin egress log: every `http.fetch` a plugin attempts, sent or
  refused (see `Firefly.Plugin.Host`), shown to staff on the plugin's
  page. An entry has the plugin, method, host, path, the response's status
  or the kind of refusal or failure, the bytes sent and received, how long
  it took and when.

  Only what's needed to see where data went: never request or response
  bodies or headers, and the path without its query string, where tokens
  often travel. Core features making requests of their own (link previews)
  aren't plugin traffic and aren't logged here.

  Entries are kept for the `plugin_egress_days` site setting (14 days by
  default); `Firefly.Moderation.TopicTimers.Scheduler` prunes older ones
  (`run_due/0`).
  """

  import Ecto.Query

  alias Firefly.{Repo, SiteSettings}
  alias Firefly.Plugins.EgressEntry

  # Failures after the request went out; every other error kind means it
  # was refused before anything was sent.
  @sent_errors [:too_large, :timeout, :failed]

  @doc """
  Records an attempt by `plugin_id` with `http.fetch` arguments `args`:
  `result` is `{:ok, response}` or `{:error, kind, message}`.
  """
  def record(plugin_id, args, result, duration_ms) do
    uri = url(args)
    blocked = match?({:error, kind, _} when kind not in @sent_errors, result)

    entry =
      Map.merge(
        %{
          plugin_id: plugin_id,
          method: method(args),
          host: uri && uri.host && String.slice(String.downcase(uri.host), 0, 255),
          path: uri && uri.host && String.slice(uri.path || "/", 0, 1_000),
          blocked: blocked,
          request_bytes: if(blocked, do: 0, else: request_bytes(args)),
          duration_ms: duration_ms,
          inserted_at: DateTime.utc_now()
        },
        outcome(result)
      )

    Repo.insert_all(EgressEntry, [entry])
    :ok
  end

  defp url(%{"url" => url}) when is_binary(url), do: URI.parse(url)
  defp url(_args), do: nil

  defp method(%{"method" => method}) when is_binary(method),
    do: method |> String.upcase() |> String.slice(0, 10)

  defp method(_args), do: "GET"

  defp request_bytes(%{"body" => body}) when is_binary(body), do: byte_size(body)
  defp request_bytes(_args), do: 0

  defp outcome({:ok, %{status: status, body: body} = response}) do
    bytes = if response[:base64], do: byte_size(Base.decode64!(body)), else: byte_size(body)
    %{status: status, error: nil, response_bytes: bytes}
  end

  defp outcome({:error, kind, _message}),
    do: %{status: nil, error: to_string(kind), response_bytes: 0}

  @doc """
  `plugin_id`'s latest entries, newest first. `filters`: `"host"` (one host)
  and `"outcome"` (`"allowed"` or `"blocked"`); blank means any.
  """
  def list(plugin_id, filters \\ %{}, limit \\ 100) do
    EgressEntry
    |> where([e], e.plugin_id == ^plugin_id)
    |> filter_host(filters["host"])
    |> filter_outcome(filters["outcome"])
    |> order_by(desc: :id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_host(query, host) when is_binary(host) and host != "",
    do: where(query, [e], e.host == ^host)

  defp filter_host(query, _host), do: query

  defp filter_outcome(query, "allowed"), do: where(query, [e], not e.blocked)
  defp filter_outcome(query, "blocked"), do: where(query, [e], e.blocked)
  defp filter_outcome(query, _outcome), do: query

  @doc "The hosts in `plugin_id`'s log, for filtering."
  def hosts(plugin_id) do
    EgressEntry
    |> where([e], e.plugin_id == ^plugin_id and not is_nil(e.host))
    |> distinct(true)
    |> order_by(:host)
    |> select([e], e.host)
    |> Repo.all()
  end

  @doc "Deletes entries older than the retention period. Returns how many."
  def run_due(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -SiteSettings.get("plugin_egress_days"), :day)
    {count, _} = Repo.delete_all(where(EgressEntry, [e], e.inserted_at < ^cutoff))
    count
  end
end
