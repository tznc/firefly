defmodule Firefly.AI.Adapters.Anthropic do
  @moduledoc """
  `Firefly.AI.Provider` for the Anthropic Messages API (`POST
  /v1/messages` under the base URL, default `https://api.anthropic.com`),
  with streaming. It has no embeddings (`embed/2` refuses): semantic
  search needs an OpenAI-compatible provider.

  A JSON answer (`json: true`) is asked for in the system prompt and taken
  from the text (see `Firefly.AI.json/1`).
  """

  @behaviour Firefly.AI.Provider

  alias Firefly.AI.Client

  @version "2023-06-01"

  @impl true
  def capabilities, do: [:chat, :stream]

  @impl true
  def chat(messages, opts) do
    provider = Keyword.fetch!(opts, :provider)

    body =
      %{
        model: provider.model,
        max_tokens: opts[:max_tokens] || provider.max_tokens,
        messages: Enum.map(messages, &%{role: to_string(&1.role), content: &1.content})
      }
      |> put_opt(:system, system(opts))
      |> put_opt(:temperature, opts[:temperature])

    headers = [
      {"x-api-key", provider.api_key || ""},
      {"anthropic-version", @version}
    ]

    case opts[:stream] do
      nil -> complete(provider, body, headers)
      on_text -> stream(provider, body, headers, on_text)
    end
  end

  defp complete(provider, body, headers) do
    case Client.post(provider, "/v1/messages", body, headers) do
      {:ok, %{"content" => content} = response} when is_list(content) ->
        text = for(%{"type" => "text", "text" => text} <- content, do: text) |> Enum.join()
        {:ok, %{text: text, usage: usage(response["usage"])}}

      {:ok, _other} ->
        {:error, "the provider's answer wasn't a message"}

      {:error, message} ->
        {:error, message}
    end
  end

  # The text arrives in content_block_delta events; the input tokens in
  # message_start and the output tokens in message_delta.
  defp stream(provider, body, headers, on_text) do
    initial = %{text: [], input: 0, output: 0, error: nil}

    collect = fn %{data: data}, state ->
      case Jason.decode(data) do
        {:ok, event} -> collect(event, state, on_text)
        {:error, _} -> state
      end
    end

    body = Map.put(body, :stream, true)

    case Client.post(provider, "/v1/messages", body, headers, sse: {initial, collect}) do
      {:ok, %{error: nil} = state} ->
        text = state.text |> Enum.reverse() |> Enum.join()
        {:ok, %{text: text, usage: %{input_tokens: state.input, output_tokens: state.output}}}

      {:ok, %{error: message}} ->
        {:error, "the provider failed: " <> message}

      {:error, message} ->
        {:error, message}
    end
  end

  defp collect(%{"type" => "content_block_delta", "delta" => %{"text" => text}}, state, on_text)
       when is_binary(text) do
    on_text.(text)
    %{state | text: [text | state.text]}
  end

  defp collect(%{"type" => "message_start", "message" => %{"usage" => usage}}, state, _on_text),
    do: %{state | input: usage["input_tokens"] || 0}

  defp collect(%{"type" => "message_delta", "usage" => usage}, state, _on_text),
    do: %{state | output: usage["output_tokens"] || state.output}

  defp collect(%{"type" => "error", "error" => %{"message" => message}}, state, _on_text),
    do: %{state | error: message}

  defp collect(_event, state, _on_text), do: state

  @impl true
  def embed(_texts, _opts), do: {:error, "Anthropic has no embeddings API"}

  defp system(opts) do
    json = if opts[:json], do: "Answer with a single JSON object and nothing else."

    case Enum.reject([opts[:system], json], &is_nil/1) do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp put_opt(body, _key, nil), do: body
  defp put_opt(body, key, value), do: Map.put(body, key, value)

  defp usage(%{} = usage),
    do: %{input_tokens: usage["input_tokens"] || 0, output_tokens: usage["output_tokens"] || 0}

  defp usage(_usage), do: %{input_tokens: 0, output_tokens: 0}
end
