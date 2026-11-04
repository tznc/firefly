defmodule Firefly.Themes.Palette do
  @moduledoc """
  The daisyUI color tokens a theme's color schemes set (`light` for the
  `firefly` theme, `dark` for `firefly-dark`), the built-in values each
  falls back to (those of the web app's `app.css`, kept in step by a
  test), and the pairs whose contrast must reach WCAG AA (4.5:1): each
  `*-content` color on its background.
  """

  @tokens ~w(base-100 base-200 base-300 base-content primary primary-content secondary
             secondary-content accent accent-content neutral neutral-content info info-content
             success success-content warning warning-content error error-content)

  @defaults %{
    "light" => %{
      "base-100" => "#ffffff",
      "base-200" => "#f7f5f1",
      "base-300" => "#e9e5de",
      "base-content" => "#2e2e2e",
      "primary" => "#db3440",
      "primary-content" => "#ffffff",
      "secondary" => "#4a4a4a",
      "secondary-content" => "#f2efea",
      "accent" => "#faaf3f",
      "accent-content" => "#3a2a0e",
      "neutral" => "#4a4a4a",
      "neutral-content" => "#f2efea",
      "info" => "#2b76c2",
      "info-content" => "#ffffff",
      "success" => "#1f7a4c",
      "success-content" => "#ffffff",
      "warning" => "#faaf3f",
      "warning-content" => "#3a2a0e",
      "error" => "#c42a35",
      "error-content" => "#ffffff"
    },
    "dark" => %{
      "base-100" => "#2a2a2a",
      "base-200" => "#222222",
      "base-300" => "#1a1a1a",
      "base-content" => "#f2efea",
      "primary" => "#e5505b",
      "primary-content" => "#1a1a1a",
      "secondary" => "#f2efea",
      "secondary-content" => "#2a2a2a",
      "accent" => "#faaf3f",
      "accent-content" => "#2a1e08",
      "neutral" => "#4a4a4a",
      "neutral-content" => "#f2efea",
      "info" => "#6ba9ea",
      "info-content" => "#10213a",
      "success" => "#5cc48f",
      "success-content" => "#0e2a1c",
      "warning" => "#fde3b8",
      "warning-content" => "#2a1e08",
      "error" => "#f0707a",
      "error-content" => "#2a0b0e"
    }
  }

  @doc "The tokens, in the order the editor shows them."
  def tokens, do: @tokens

  @doc "The schemes: `light` and `dark`."
  def schemes, do: ~w(light dark)

  @doc "The data-theme each scheme styles."
  def data_theme("light"), do: "firefly"
  def data_theme("dark"), do: "firefly-dark"

  @doc "The built-in values, by scheme and token."
  def defaults, do: @defaults

  @doc "Pairs `{foreground, background}` that must be readable."
  def pairs do
    [{"base-content", "base-100"}, {"base-content", "base-200"}, {"base-content", "base-300"}] ++
      for color <- ~w(primary secondary accent neutral info success warning error),
          do: {color <> "-content", color}
  end
end
