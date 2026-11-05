defmodule Firefly.Embedding.EmbeddableHost do
  @moduledoc """
  A site allowed to embed topics as comments (see `Firefly.Embedding`):
  its `host` (`blog.example.com`), optionally the paths pages must start
  with (`allowed_paths`; any path when empty), the category its topics go
  in, a CSS class for the embed page's body and a tag for its topics.
  """
  use Ecto.Schema
  use Firefly.Changeset

  alias Firefly.Discussion.Category

  schema "embeddable_hosts" do
    field(:host, :string)
    field(:allowed_paths, {:array, :string}, default: [])
    field(:class_name, :string)
    field(:tag, :string)
    belongs_to(:category, Category)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [:host, :allowed_paths, :category_id, :class_name, :tag])
    |> update_change(:host, &normalize_host/1)
    |> validate_required([:host])
    |> validate_format(
      :host,
      ~r/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:\d+)?\z/,
      message: "must be a host name, like blog.example.com"
    )
    |> update_change(:allowed_paths, &normalize_paths/1)
    |> validate_format(:class_name, ~r/\A[a-zA-Z0-9_ -]*\z/,
      message: "letters, digits, - and _ only"
    )
    |> validate_length(:tag, max: 100)
    |> foreign_key_constraint(:category_id)
    |> unique_constraint(:host)
  end

  # "https://Blog.Example.com/" -> "blog.example.com"
  defp normalize_host(host) do
    host
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r{\A[a-z]+://}, "")
    |> String.trim_trailing("/")
  end

  defp normalize_paths(paths) do
    paths
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&if(String.starts_with?(&1, "/"), do: &1, else: "/" <> &1))
  end
end
