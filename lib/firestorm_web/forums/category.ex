defmodule FirestormWeb.Forums.Category do
  @moduledoc """
  Schema for forum categories. Categories can have one level of
  subcategories (`parent_id`), an optional description and color, and are
  ordered by `position`, then title.
  """

  use Ecto.Schema
  import Ecto.Changeset, warn: false

  alias FirestormWeb.Forums.Thread
  alias FirestormWeb.Forums.Slugs.CategoryTitleSlug

  schema "forums_categories" do
    field(:title, :string)
    field(:slug, CategoryTitleSlug.Type)
    field(:description, :string)
    field(:color, :string)
    field(:position, :integer, default: 0)
    belongs_to(:parent, __MODULE__)
    has_many(:children, __MODULE__, foreign_key: :parent_id)
    has_many(:threads, Thread)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = category, attrs \\ %{}) do
    category
    |> cast(attrs, [:title, :description, :color, :position, :parent_id], empty_values: [""])
    |> validate_required([:title])
    |> validate_length(:description, max: 1000)
    |> validate_format(:color, ~r/^#[0-9a-fA-F]{6}$/, message: "must be a hex color like #3b82f6")
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_parent()
    |> foreign_key_constraint(:parent_id)
    |> CategoryTitleSlug.maybe_generate_slug()
    |> CategoryTitleSlug.unique_constraint()
  end

  # One level deep: a subcategory's parent must be a top-level category, and a
  # category with subcategories can't become one.
  defp validate_parent(changeset) do
    case get_change(changeset, :parent_id) do
      nil ->
        changeset

      parent_id ->
        category = changeset.data
        repo = FirestormWeb.Repo

        cond do
          category.id && parent_id == category.id ->
            add_error(changeset, :parent_id, "can't be the category itself")

          match?(%{parent_id: id} when not is_nil(id), repo.get(__MODULE__, parent_id)) ->
            add_error(changeset, :parent_id, "must be a top-level category")

          category.id && has_children?(repo, category.id) ->
            add_error(
              changeset,
              :parent_id,
              "a category with subcategories can't be a subcategory"
            )

          true ->
            changeset
        end
    end
  end

  defp has_children?(repo, id) do
    import Ecto.Query
    repo.exists?(from(c in __MODULE__, where: c.parent_id == ^id))
  end
end
