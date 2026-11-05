defmodule Firefly.Discussion.Slugs.TitleSlug do
  @moduledoc """
  Module that makes it easy to create title slugs that autogenerate unique
  titles.
  """

  defmacro __using__(module) do
    quote do
      use EctoAutoslugField.Slug, from: :title, to: :slug
      alias Firefly.Repo
      import Ecto.Query

      # Only lowercase letters, digits and dashes (Slugify keeps control
      # characters), at most 200 of them; a title of only emoji or punctuation ("🔥🔥", "!!!")
      # has none, and gets "untitled" (looking up a nil slug would raise).
      def build_slug(sources) do
        base_slug =
          (super(sources) || "")
          |> String.replace(~r/[^a-z0-9-]+/, "")
          |> String.replace(~r/-{2,}/, "-")
          |> String.trim("-")
          # Room for a "-N" suffix in the 255-character column.
          |> String.slice(0, 200)
          |> String.trim_trailing("-")

        get_unused_slug(if(base_slug == "", do: "untitled", else: base_slug), 0)
      end

      def get_unused_slug(base_slug, number) do
        slug = get_slug(base_slug, number)

        if slug_used?(slug) do
          get_unused_slug(base_slug, number + 1)
        else
          slug
        end
      end

      def slug_used?(slug) do
        unquote(module)
        |> where(slug: ^slug)
        |> Repo.one()
      end

      def get_slug(base_slug, 0), do: base_slug

      def get_slug(base_slug, number) do
        "#{base_slug}-#{number}"
      end
    end
  end
end
