defmodule Firefly.Themes.Contrast do
  @moduledoc """
  WCAG 2 contrast: the ratio of two colors' relative luminances (1 to 21),
  and the pairs of a theme's color schemes that fall short of AA (4.5:1,
  for normal-size text).
  """

  alias Firefly.Themes.Palette

  @aa 4.5

  @doc "The contrast ratio between two `#rrggbb` colors."
  def ratio(foreground, background) do
    {darker, lighter} = Enum.min_max([luminance(foreground), luminance(background)])
    (lighter + 0.05) / (darker + 0.05)
  end

  defp luminance("#" <> hex) do
    <<r::binary-2, g::binary-2, b::binary-2>> = String.downcase(hex)
    [r, g, b] = Enum.map([r, g, b], &channel(String.to_integer(&1, 16) / 255))
    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  defp channel(c) when c <= 0.03928, do: c / 12.92
  defp channel(c), do: :math.pow((c + 0.055) / 1.055, 2.4)

  @doc """
  The pairs of `colors` (by scheme, then token; missing tokens take the
  built-in values) below AA: `%{scheme, foreground, background, ratio}`,
  ratio rounded to two decimals.
  """
  def warnings(colors) do
    for scheme <- Palette.schemes(),
        palette = Map.merge(Palette.defaults()[scheme], Map.get(colors || %{}, scheme, %{})),
        {foreground, background} <- Palette.pairs(),
        ratio = ratio(palette[foreground], palette[background]),
        ratio < @aa do
      %{
        scheme: scheme,
        foreground: foreground,
        background: background,
        ratio: Float.round(ratio, 2)
      }
    end
  end
end
