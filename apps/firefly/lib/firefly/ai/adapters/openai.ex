defmodule Firefly.AI.Adapters.OpenAI do
  @moduledoc """
  `Firefly.AI.Provider` for OpenAI-compatible APIs: Chat Completions
  (`POST /chat/completions` under the base URL, default
  `https://api.openai.com/v1`), with streaming, and Embeddings (`POST
  /embeddings`, with the provider's `embedding_model`, or its `model`).
  The same adapter serves OpenAI and the servers that speak its API
  (Ollama at `http://localhost:11434/v1`, vLLM, LM Studio and others).

  A JSON answer (`json: true`) asks for `response_format: json_object`.
  """

  @behaviour Firefly.AI.Provider

  alias Firefly.AI.Client

  @impl true
  def capabilities, do: [:chat, :stream, :embed]

  @impl true
  def chat(messages, opts) do
    provider = Keyword.fetch!(opts, :provider)

    system = if opts[:system], do: [%{role: "system", content: opts[:system]}], else: []

    body =
      %{
        model: provider.model,
        max_tokens: opts[:max_tokens] || provider.max_tokens,
        messages: system ++ Enum.map(messages, &%{role: to_string(&1.role), content: &1.content})
      }
      |> put_opt(:temperature, opts[:temperature])
      |> put_opt(:response_format, if(opts[:json], do: %{type: "json_object"}))

    case opts[:stream] do
      nil -> complete(provider, body)
      on_text -> stream(provider, body, on_text)
    end
  end

  defp complete(provider, body) do
    case Client.post(provider, "/chat/completions", body, headers(provider)) do
      {:ok, %{"choices" => [%{"message" => %{"content" => text}} | _]} = response} ->
        {:ok, %{text: text || "", usage: usage(response["usage"])}}

      {:ok, _other} ->
        {:error, "the provider's answer had no choices"}

      {:error, message} ->
        {:error, message}
    end
  end

  # Chunks carry text in choices[0].delta.content; the last one the usage
  # (asked for with stream_options), then `[DONE]`.
  defp stream(provider, body, on_text) do
    body = Map.merge(body, %{stream: true, stream_options: %{include_usage: true}})

    collect = fn
      %{data: "[DONE]"}, state ->
        state

      %{data: data}, state ->
        case Jason.decode(data) do
          {:ok, chunk} -> collect(chunk, state, on_text)
          {:error, _} -> state
        end
    end

    initial = %{text: [], usage: usage(nil)}

    case Client.post(provider, "/chat/completions", body, headers(provider),
           sse: {initial, collect}
         ) do
      {:ok, state} ->
        {:ok, %{text: state.text |> Enum.reverse() |> Enum.join(), usage: state.usage}}

      {:error, message} ->
        {:error, message}
    end
  end

  defp collect(chunk, state, on_text) do
    state =
      case chunk do
        %{"choices" => [%{"delta" => %{"content" => text}} | _]} when is_binary(text) ->
          on_text.(text)
          %{state | text: [text | state.text]}

        _other ->
          state
      end

    case chunk do
      %{"usage" => %{} = usage} -> %{state | usage: usage(usage)}
      _other -> state
    end
  end

  @impl true
  def embed(texts, opts) do
    provider = Keyword.fetch!(opts, :provider)
    body = %{model: provider.embedding_model || provider.model, input: texts}

    case Client.post(provider, "/embeddings", body, headers(provider)) do
      {:ok, %{"data" => data} = response} when is_list(data) ->
        vectors = data |> Enum.sort_by(& &1["index"]) |> Enum.map(& &1["embedding"])

        if length(vectors) == length(texts),
          do: {:ok, %{vectors: vectors, usage: usage(response["usage"])}},
          else:
            {:error,
             "the provider returned #{length(vectors)} embeddings for #{length(texts)} texts"}

      {:ok, _other} ->
        {:error, "the provider's answer had no embeddings"}

      {:error, message} ->
        {:error, message}
    end
  end

  # Local servers often need no key.
  defp headers(%{api_key: key}) when is_binary(key) and key != "",
    do: [{"authorization", "Bearer " <> key}]

  defp headers(_provider), do: []

  defp put_opt(body, _key, nil), do: body
  defp put_opt(body, key, value), do: Map.put(body, key, value)

  defp usage(%{} = usage),
    do: %{
      input_tokens: usage["prompt_tokens"] || 0,
      output_tokens: usage["completion_tokens"] || 0
    }

  defp usage(_usage), do: %{input_tokens: 0, output_tokens: 0}
end
