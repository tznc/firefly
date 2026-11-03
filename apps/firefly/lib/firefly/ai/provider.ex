defmodule Firefly.AI.Provider do
  @moduledoc """
  The contract between Firefly's AI features and a model provider's API.
  Each adapter (`Firefly.AI.Adapters.Anthropic`,
  `Firefly.AI.Adapters.OpenAI`) implements it; features never talk to an
  API directly, so any provider an admin configures serves any feature its
  capabilities allow.

  Every callback gets the configured provider (`Firefly.AI.ProviderConfig`)
  in `opts[:provider]`, plus:

    * `:system` - the system prompt
    * `:max_tokens` - the most tokens to generate (default: the provider's)
    * `:temperature` - sampling temperature
    * `:json` - true: ask for a JSON object as the answer
    * `:stream` - a function called with each piece of text as it arrives
      (adapters with the `:stream` capability; the full answer is still
      returned at the end)

  Errors are `{:error, message}`, a message an admin can act on.
  """

  @typedoc "A turn of the conversation."
  @type message :: %{role: :user | :assistant, content: String.t()}

  @typedoc "Tokens the request used."
  @type usage :: %{input_tokens: non_neg_integer, output_tokens: non_neg_integer}

  @type capability :: :chat | :stream | :embed

  @doc "Generates the next assistant turn after `messages`."
  @callback chat([message], keyword) ::
              {:ok, %{text: String.t(), usage: usage}} | {:error, String.t()}

  @doc """
  Embeds each of `texts` as a vector, in order. An adapter without the
  `:embed` capability returns an error.
  """
  @callback embed([String.t()], keyword) ::
              {:ok, %{vectors: [[float]], usage: usage}} | {:error, String.t()}

  @doc "What the adapter can do."
  @callback capabilities() :: [capability]
end
