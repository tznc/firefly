defmodule Firefly.AI.Client do
  @moduledoc """
  The HTTP side of the adapters (see `Firefly.AI.Provider`): JSON POSTs to
  a provider's API with Req, and server-sent event streams.

    * Requests go to public addresses only (resolved here and pinned, the
      same guard as `Firefly.Plugins.HTTP`), unless the provider allows
      private ones. Redirects aren't followed.
    * Each request may take the provider's `timeout_seconds`; connecting,
      at most 10 seconds.
    * 429 and 5xx answers, refused connections and dropped connections are
      retried twice, after the `Retry-After` the provider asked for or an
      exponential backoff (1 then 2 seconds), at most 30 seconds. Timeouts
      aren't: the request already took as long as it may.

  `config :firefly, Firefly.AI, retry_base_ms:` sets the backoff's base
  (tests use 0).
  """

  alias Firefly.AI.ProviderConfig
  alias Firefly.Plugins.HTTP

  @max_retries 2
  @max_delay 30_000

  @doc """
  POSTs `body` as JSON to `path` under the provider's base URL, with
  `headers`. The decoded response body, or `{:error, message}`.

  With `sse: {acc, fun}`, the response is read as a server-sent event
  stream: `fun` reduces each event (`%{event: name | nil, data: text}`)
  into `acc` as it arrives, and the result is `{:ok, acc}`. A stream cut
  off midway isn't retried (its first part was already used).
  """
  @spec post(ProviderConfig.t(), String.t(), map, [{String.t(), String.t()}], keyword) ::
          {:ok, term} | {:error, String.t()}
  def post(%ProviderConfig{} = provider, path, body, headers, opts \\ []) do
    Firefly.Telemetry.span([:firefly, :ai, :request], %{adapter: provider.adapter}, fn ->
      result = request(provider, path, body, headers, opts)
      {result, %{result: if(match?({:ok, _}, result), do: "ok", else: "error")}}
    end)
  end

  defp request(provider, path, body, headers, opts) do
    with {:ok, url, connect} <- route(provider, provider.base_url <> path) do
      timeout = provider.timeout_seconds * 1_000

      request =
        [
          method: :post,
          url: url,
          headers: headers,
          json: body,
          receive_timeout: timeout,
          connect_options: [timeout: min(timeout, 10_000)] ++ connect,
          redirect: false,
          retry: if(opts[:sse], do: &retry_status/2, else: &retry/2),
          max_retries: @max_retries,
          retry_log_level: false
        ]
        |> Req.new()
        # An HTTP client span; no trace headers go to the provider.
        |> OpentelemetryReq.attach()

      request =
        if sse = opts[:sse], do: Req.merge(request, into: stream(sse)), else: request

      case Req.request(request) do
        {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
          {:ok, result(response, opts[:sse])}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, "the provider answered #{status}: #{error_detail(body)}"}

        {:error, %Req.TransportError{reason: :timeout}} ->
          {:error, "the provider didn't answer within #{provider.timeout_seconds} seconds"}

        {:error, exception} ->
          {:error, "the request failed: " <> Exception.message(exception)}
      end
    end
  end

  # The URL to request and the connection options: the host resolved to a
  # public address (and the request sent there, so a second lookup can't
  # swap in an internal one) unless the provider may be private.
  defp route(%ProviderConfig{allow_private: true}, url), do: {:ok, url, []}

  defp route(_provider, url) do
    uri = URI.parse(url)

    case HTTP.resolve(uri.host) do
      {:ok, ip} ->
        {:ok, HTTP.target(uri, ip), [hostname: uri.host]}

      {:error, message} ->
        {:error,
         message <> " (allow private addresses for a model served on this machine or network)"}
    end
  end

  defp result(response, nil), do: response.body
  defp result(response, {acc, _fun}), do: Req.Response.get_private(response, :sse_acc, acc)

  defp retry(request, %Req.TransportError{reason: reason})
       when reason in [:econnrefused, :closed],
       do: {:delay, backoff(request)}

  defp retry(request, response_or_exception), do: retry_status(request, response_or_exception)

  defp retry_status(request, %Req.Response{status: status} = response)
       when status == 429 or status in 500..599 do
    after_header = Req.Response.get_retry_after(response)
    {:delay, min(after_header || backoff(request), @max_delay)}
  end

  defp retry_status(_request, _response_or_exception), do: false

  defp backoff(request) do
    base = Application.get_env(:firefly, Firefly.AI, [])[:retry_base_ms] || 1_000
    base * 2 ** Req.Request.get_private(request, :req_retry_count, 0)
  end

  # Reads a successful response as events; anything else is kept as the
  # body, for the error message.
  defp stream({acc, fun}) do
    fn {:data, data}, {request, response} ->
      {:cont, {request, receive_data(response, data, acc, fun)}}
    end
  end

  defp receive_data(%Req.Response{status: status} = response, data, acc, fun)
       when status in 200..299 do
    buffer = Req.Response.get_private(response, :sse_buffer, "") <> data
    {events, rest} = sse_events(buffer)
    acc = Enum.reduce(events, Req.Response.get_private(response, :sse_acc, acc), fun)

    response
    |> Req.Response.put_private(:sse_buffer, rest)
    |> Req.Response.put_private(:sse_acc, acc)
  end

  defp receive_data(response, data, _acc, _fun) do
    body = if is_binary(response.body), do: response.body, else: ""
    %{response | body: body <> data}
  end

  @doc """
  Splits `buffer` into the complete server-sent events in it and the
  incomplete rest: `{[%{event: name | nil, data: text}], rest}`. Events
  without data (comments, keep-alives) are dropped.
  """
  def sse_events(buffer) do
    {complete, [rest]} = buffer |> String.split(~r/\r?\n\r?\n/) |> Enum.split(-1)
    {Enum.flat_map(complete, &event/1), rest}
  end

  defp event(block) do
    lines = String.split(block, ~r/\r?\n/)
    data = for "data:" <> value <- lines, do: String.replace_prefix(value, " ", "")

    name =
      Enum.find_value(lines, fn
        "event:" <> name -> String.trim(name)
        _line -> nil
      end)

    if data == [], do: [], else: [%{event: name, data: Enum.join(data, "\n")}]
  end

  # Both APIs explain errors as `{"error": {"message": ...}}`.
  defp error_detail(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> error_detail(decoded)
      _text -> String.slice(body, 0, 300)
    end
  end

  defp error_detail(%{"error" => %{"message" => message}}) when is_binary(message),
    do: String.slice(message, 0, 300)

  defp error_detail(%{"error" => message}) when is_binary(message),
    do: String.slice(message, 0, 300)

  defp error_detail(body), do: body |> inspect() |> String.slice(0, 300)
end
