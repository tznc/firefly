defmodule FireflyWeb.AIComponents do
  @moduledoc """
  What AI features show (see `Firefly.AI`). Everything a model wrote is
  marked with `ai_label/1`, so nobody takes it for a member's words.
  """
  use Phoenix.Component

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
end
