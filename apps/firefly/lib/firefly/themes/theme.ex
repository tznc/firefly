defmodule Firefly.Themes.Theme do
  @moduledoc """
  A theme, or a theme component (`component: true`) that themes include
  (see `Firefly.Themes`): `colors` (daisyUI tokens by scheme, `light` and
  `dark`, see `Firefly.Themes.Palette`), custom `css`, `head_html`,
  `header_html` and `footer_html`, whether its HTML may run scripts
  (`allow_scripts`, admins only), and whether members may pick it
  (`user_selectable`). `version` goes up with every change, naming the
  compiled stylesheet (`compiled_css`) so browsers cache it for good.
  """

  use Ecto.Schema
  use Firefly.Changeset

  alias Firefly.Themes.{Palette, ThemeAsset}

  @max_css 100_000
  @max_html 20_000

  schema "themes" do
    field(:name, :string)
    field(:description, :string)
    field(:component, :boolean, default: false)
    field(:colors, :map, default: %{})
    field(:css, :string, default: "")
    field(:head_html, :string, default: "")
    field(:header_html, :string, default: "")
    field(:footer_html, :string, default: "")
    field(:allow_scripts, :boolean, default: false)
    field(:user_selectable, :boolean, default: false)
    field(:version, :integer, default: 1)
    field(:compiled_css, :string, default: "")
    field(:source_url, :string)
    # Set by the package that installed it (see Firefly.Packages): which
    # of its themes this is, and a hash of what it set (local edits change it).
    belongs_to(:package, Firefly.Packages.Package)
    field(:package_key, :string)
    field(:package_hash, :string)

    many_to_many(:components, __MODULE__,
      join_through: "theme_components",
      join_keys: [theme_id: :id, component_id: :id],
      on_replace: :delete
    )

    has_many(:assets, ThemeAsset)

    timestamps(type: :utc_datetime)
  end

  @doc "The largest custom CSS, in bytes."
  def max_css, do: @max_css

  @doc "The largest HTML of each kind, in bytes."
  def max_html, do: @max_html

  @doc "What admins edit (not `allow_scripts`, which has its own logged action)."
  def changeset(%__MODULE__{} = theme, attrs) do
    theme
    |> cast(attrs, [
      :name,
      :description,
      :component,
      :colors,
      :css,
      :head_html,
      :header_html,
      :footer_html,
      :user_selectable,
      :source_url
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 60)
    |> validate_length(:description, max: 1_000)
    |> update_change(:colors, &normalize_colors/1)
    |> validate_change(:colors, &validate_colors/2)
    |> validate_bytes(:css, @max_css)
    |> validate_change(:css, &validate_css/2)
    |> validate_bytes(:head_html, @max_html)
    |> validate_bytes(:header_html, @max_html)
    |> validate_bytes(:footer_html, @max_html)
    |> unique_constraint(:name, name: :themes_lower_name_index, message: "is taken")
  end

  # Empty strings are tokens left at their built-in value.
  defp normalize_colors(colors) when is_map(colors) do
    for {scheme, tokens} <- colors, is_map(tokens), into: %{} do
      {scheme,
       for({token, value} <- tokens, is_binary(value), String.trim(value) != "", into: %{}) do
         {token, value |> String.trim() |> String.downcase()}
       end}
    end
  end

  defp normalize_colors(other), do: other

  defp validate_colors(:colors, colors) when is_map(colors) do
    errors =
      for {scheme, tokens} <- colors,
          {token, value} <- tokens,
          not (scheme in Palette.schemes() and token in Palette.tokens() and
                 value =~ ~r/^#[0-9a-f]{6}$/),
          do: "#{scheme} #{token}"

    if errors == [],
      do: [],
      else: [colors: "must be colors like #3b82f6 (check #{Enum.join(errors, ", ")})"]
  end

  defp validate_colors(:colors, _other), do: [colors: "is invalid"]

  defp validate_bytes(changeset, field, max) do
    validate_change(changeset, field, fn ^field, value ->
      if byte_size(value || "") > max,
        do: [{field, "must be at most #{div(max, 1000)} KB"}],
        else: []
    end)
  end

  # The stylesheet is served as a file, so it can't break out into the page;
  # this catches mistakes: unbalanced braces and markup pasted in.
  defp validate_css(:css, css) do
    stripped = Regex.replace(~r{/\*.*?\*/|"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'}s, css, "")

    cond do
      String.contains?(String.downcase(css), "</style") or String.contains?(css, "<script") ->
        [css: "must be CSS, not HTML"]

      balance(stripped) != 0 ->
        [css: "has unbalanced braces"]

      true ->
        []
    end
  end

  defp balance(css) do
    Enum.reduce_while(String.graphemes(css), 0, fn
      "{", depth -> {:cont, depth + 1}
      "}", 0 -> {:halt, -1}
      "}", depth -> {:cont, depth - 1}
      _char, depth -> {:cont, depth}
    end)
  end
end
