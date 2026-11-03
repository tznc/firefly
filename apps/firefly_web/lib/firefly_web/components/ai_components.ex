defmodule FireflyWeb.AIComponents do
  @moduledoc """
  What AI features show (see `Firefly.AI`). Everything a model wrote is
  marked with `ai_label/1`, so nobody takes it for a member's words.

  Results being made are `%{status: :loading, text: text_so_far}`, then
  `%{status: :done, text: text}` or `%{status: {:error, message}}`.
  """
  use Phoenix.Component

  import FireflyWeb.ForumComponents, only: [markdown: 1]

  @doc "The mark on AI-generated text."
  attr :class, :any, default: nil
  attr :rest, :global

  def ai_label(assigns) do
    ~H"""
    <span
      class={["badge badge-sm badge-soft badge-secondary gap-1", @class]}
      title="Written by an AI model; it can be wrong."
      data-ai-generated
      {@rest}
    >
      <span class="hero-sparkles size-3" aria-hidden="true"></span> AI-generated
    </span>
    """
  end

  @doc "An AI result (see the moduledoc): Markdown, labelled, as it streams in."
  attr :id, :string, required: true
  attr :result, :map, required: true
  attr :viewer, :any, default: nil
  attr :title, :string, default: nil

  def ai_result(assigns) do
    ~H"""
    <div id={@id} class="space-y-1" aria-live="polite">
      <div class="flex items-center gap-2 text-sm">
        <span :if={@title} class="font-medium">{@title}</span>
        <.ai_label />
        <span :if={@result.status == :loading} class="loading loading-dots loading-xs" aria-label="Writing"></span>
      </div>
      <p :if={match?({:error, _}, @result.status)} class="text-sm text-error">{elem(@result.status, 1)}</p>
      <.markdown :if={@result[:text] not in [nil, ""]} id={@id <> "-body"} body={@result.text} viewer={@viewer} />
    </div>
    """
  end

  @doc """
  The composer's AI helper buttons (see `FireflyWeb.AIComposer`), and the
  suggestion to use or dismiss.
  """
  attr :helpers, :list, required: true
  attr :suggestion, :map, default: nil

  def composer_helpers(assigns) do
    ~H"""
    <div :if={@helpers != []} id="ai-helpers" class="space-y-2">
      <div class="flex flex-wrap items-center gap-1">
        <button
          :for={{helper, label} <- [proofread: "Proofread", title: "Suggest a title", tags: "Suggest tags"]}
          :if={helper in @helpers}
          type="button"
          phx-click="ai_helper"
          phx-value-helper={helper}
          class="btn btn-ghost btn-xs"
          disabled={@suggestion && @suggestion.status == :loading}
        >
          <span class="hero-sparkles size-3" aria-hidden="true"></span> {label}
        </button>
      </div>
      <div :if={@suggestion} id="ai-suggestion" class="rounded-box border border-secondary/40 bg-base-100 p-3 text-sm">
        <div class="mb-1 flex items-center gap-2">
          <.ai_label />
          <span :if={@suggestion.status == :loading} class="loading loading-dots loading-xs" aria-label="Writing"></span>
        </div>
        <p :if={match?({:error, _}, @suggestion.status)} class="text-error">{elem(@suggestion.status, 1)}</p>
        <div :if={@suggestion.status == :done} class="space-y-2">
          <p class="whitespace-pre-wrap">{suggestion_text(@suggestion.value)}</p>
          <div class="flex gap-1">
            <button type="button" phx-click="ai_apply" class="btn btn-primary btn-xs">Use this</button>
            <button type="button" phx-click="ai_dismiss" class="btn btn-ghost btn-xs">Dismiss</button>
          </div>
        </div>
        <button :if={@suggestion.status != :done} type="button" phx-click="ai_dismiss" class="btn btn-ghost btn-xs">
          Dismiss
        </button>
      </div>
    </div>
    """
  end

  defp suggestion_text(tags) when is_list(tags), do: Enum.join(tags, ", ")
  defp suggestion_text(text), do: text

  @doc "A result as it streams in: `text` added to what came before."
  def append_text(%{status: :loading} = result, text), do: %{result | text: result.text <> text}
  def append_text(result, _text), do: result

  @doc "A result from a `start_async` task returning `{:ok, %{text:}}` or `{:error, reason}`."
  def ai_outcome({:ok, {:ok, %{text: text}}}), do: %{status: :done, text: text}
  def ai_outcome({:ok, {:error, reason}}), do: %{status: {:error, Firefly.AI.message(reason)}}

  def ai_outcome({:exit, _reason}),
    do: %{status: {:error, Firefly.AI.message(:provider_failed)}}

  @doc """
  The viewer's language for translations: their browser's (sent when the
  LiveView connects), else English.
  """
  def viewer_language(socket) do
    if Phoenix.LiveView.connected?(socket),
      do:
        Firefly.AI.Translations.language(
          (Phoenix.LiveView.get_connect_params(socket) || %{})["locale"]
        ),
      else: "en"
  end
end
