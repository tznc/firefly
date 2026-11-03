defmodule Firefly.AI.FakeProvider do
  @moduledoc """
  A fake AI provider for tests: a local HTTP server (Bandit) answering
  with a function of the request, so adapters are tested over real HTTP
  without reaching any real provider.

      url = FakeProvider.start(&FakeProvider.openai_reply(&1, "Hello"))
      provider = FakeProvider.provider_fixture(url)

  Every request is also sent to the test process as `{:ai_request,
  %{path:, headers:, body:}}`.
  """

  # Test support, for any app's tests: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]

  import Plug.Conn

  @behaviour Plug

  @doc """
  Starts a server (stopped with the test) whose answers `handler` (a
  function of the conn, with `conn.assigns.body` decoded) makes. Returns
  its base URL.
  """
  def start(handler) do
    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: {__MODULE__, {handler, self()}}, ip: :loopback, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    "http://127.0.0.1:#{port}"
  end

  @doc "Starts a server answering every chat request (OpenAI-compatible) with `text`."
  def start_openai(text), do: start(&openai_reply(&1, text))

  @doc "Creates a provider for the server at `url` (private addresses allowed)."
  def provider_fixture(url, attrs \\ %{}) do
    {:ok, provider} =
      %Firefly.AI.ProviderConfig{}
      |> Firefly.AI.ProviderConfig.changeset(
        Map.merge(
          %{
            "name" => "Fake #{System.unique_integer([:positive])}",
            "adapter" => "openai",
            "base_url" => url,
            "api_key" => "sk-test",
            "model" => "test-model",
            "allow_private" => true
          },
          attrs
        )
      )
      |> Firefly.Repo.insert()

    provider
  end

  @doc """
  Turns AI on and `features` on with `provider` (as `admin`, which
  `Firefly.AI.update_feature/3` logs).
  """
  def enable(provider, features, admin, attrs \\ %{}) do
    {:ok, _} = Firefly.SiteSettings.update(%{"ai_enabled" => "true"}, admin)

    for feature <- List.wrap(features) do
      {:ok, _} =
        Firefly.AI.update_feature(
          feature,
          Map.merge(%{provider_id: provider.id, enabled: true}, attrs),
          admin
        )
    end

    :ok
  end

  @doc """
  An OpenAI-compatible chat completion answering `text` (streamed in two
  chunks when the request asks for a stream).
  """
  def openai_reply(conn, text, usage \\ %{"prompt_tokens" => 12, "completion_tokens" => 5})

  def openai_reply(%{assigns: %{body: %{"stream" => true}}} = conn, text, usage) do
    {first, second} = String.split_at(text, div(String.length(text), 2))

    sse(conn, [
      {nil, %{"choices" => [%{"delta" => %{"content" => first}}]}},
      {nil, %{"choices" => [%{"delta" => %{"content" => second}}]}},
      {nil, %{"choices" => [], "usage" => usage}},
      {nil, "[DONE]"}
    ])
  end

  def openai_reply(conn, text, usage) do
    json(conn, 200, %{
      "choices" => [%{"index" => 0, "message" => %{"role" => "assistant", "content" => text}}],
      "usage" => usage
    })
  end

  @doc "An Anthropic message answering `text`."
  def anthropic_reply(conn, text) do
    json(conn, 200, %{
      "type" => "message",
      "content" => [%{"type" => "text", "text" => text}],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 4}
    })
  end

  @doc "Answers `body` as JSON with `status`."
  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  @doc "Answers with server-sent events: `events` are `{name | nil, data}`."
  def sse(conn, events) do
    conn =
      conn
      |> put_resp_content_type("text/event-stream")
      |> send_chunked(200)

    Enum.reduce(events, conn, fn {name, data}, conn ->
      data = if is_binary(data), do: data, else: Jason.encode!(data)
      event = if name, do: "event: #{name}\n", else: ""
      {:ok, conn} = chunk(conn, event <> "data: #{data}\n\n")
      conn
    end)
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, {handler, test_pid}) do
    {:ok, raw, conn} = read_body(conn)
    body = if raw == "", do: nil, else: Jason.decode!(raw)

    send(
      test_pid,
      {:ai_request, %{path: conn.request_path, headers: conn.req_headers, body: body}}
    )

    handler.(assign(conn, :body, body))
  end
end
