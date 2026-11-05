defmodule Firefly.AI.ProviderConfig do
  @moduledoc """
  An AI provider an admin set up at `/staff/ai` (see `Firefly.AI`): its
  `adapter` (`"anthropic"` for the Anthropic Messages API, `"openai"` for
  any OpenAI-compatible API: OpenAI, Ollama, vLLM, LM Studio and others),
  `base_url`, `api_key` (encrypted at rest, see `Firefly.Vault`),
  the `model` id for chat and, for embeddings, `embedding_model`, the
  most tokens an answer may have, and how long a request may take.

  Requests go only to public addresses (the same guard as plugins'
  requests, `Firefly.Plugins.HTTP`) unless `allow_private` is set, for a
  model served on this machine or the local network.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @adapters %{
    "anthropic" => Firefly.AI.Adapters.Anthropic,
    "openai" => Firefly.AI.Adapters.OpenAI
  }
  @default_urls %{
    "anthropic" => "https://api.anthropic.com",
    "openai" => "https://api.openai.com/v1"
  }

  schema "ai_providers" do
    field(:name, :string)
    field(:adapter, :string, default: "openai")
    field(:base_url, :string)
    field(:api_key, Firefly.Encrypted.Binary, redact: true)
    field(:model, :string)
    field(:embedding_model, :string)
    field(:max_tokens, :integer, default: 1024)
    field(:timeout_seconds, :integer, default: 60)
    field(:allow_private, :boolean, default: false)

    timestamps(type: :naive_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc "The adapters, by name, in display order."
  def adapters, do: [{"OpenAI-compatible", "openai"}, {"Anthropic", "anthropic"}]

  @doc "The module implementing `Firefly.AI.Provider` for the provider's adapter."
  def module(%__MODULE__{adapter: adapter}), do: Map.fetch!(@adapters, adapter)

  @doc "The adapter's default base URL."
  def default_url(adapter), do: @default_urls[adapter]

  @doc """
  A changeset for the provider form. A blank `api_key` keeps the stored
  one (the form never shows it); `clear_api_key` removes it.
  """
  def changeset(%__MODULE__{} = provider, attrs) do
    provider
    |> cast(attrs, [
      :name,
      :adapter,
      :base_url,
      :model,
      :embedding_model,
      :max_tokens,
      :timeout_seconds,
      :allow_private
    ])
    |> put_api_key(attrs)
    |> validate_required([:name, :adapter, :model])
    |> validate_inclusion(:adapter, Map.keys(@adapters))
    |> default_base_url()
    |> validate_length(:name, max: 60)
    |> validate_length(:model, max: 200)
    |> validate_length(:embedding_model, max: 200)
    |> validate_length(:base_url, max: 500)
    |> validate_change(:base_url, &url_errors/2)
    |> validate_number(:max_tokens, greater_than: 0, less_than_or_equal_to: 128_000)
    |> validate_number(:timeout_seconds, greater_than: 0, less_than_or_equal_to: 600)
    |> unique_constraint(:name)
  end

  defp put_api_key(changeset, attrs) do
    cond do
      (attrs["clear_api_key"] || attrs[:clear_api_key]) in ["true", true] ->
        put_change(changeset, :api_key, nil)

      is_binary(key = attrs["api_key"] || attrs[:api_key]) and String.trim(key) != "" ->
        changeset
        |> put_change(:api_key, String.trim(key))
        |> validate_length(:api_key, max: 500)

      true ->
        changeset
    end
  end

  defp default_base_url(changeset) do
    case get_field(changeset, :base_url) do
      blank when blank in [nil, ""] ->
        put_change(changeset, :base_url, default_url(get_field(changeset, :adapter)))

      url ->
        put_change(changeset, :base_url, url |> String.trim() |> String.trim_trailing("/"))
    end
  end

  defp url_errors(:base_url, url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and host not in [nil, ""] ->
        []

      _ ->
        [base_url: "must be an http or https URL"]
    end
  end
end
