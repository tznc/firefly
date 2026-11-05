defmodule Firefly.Repo do
  @moduledoc """
  The repository. Every changeset it inserts or updates loses its NUL
  characters first (see `Firefly.Text.strip_nul_changes/1`): PostgreSQL
  can't store them. Casting strips them already (`Firefly.Changeset`);
  this catches what was put into a changeset without casting, on every
  write path (contexts, `Ecto.Multi`, jobs, the database admin, plugins).

  A write PostgreSQL still refuses for its text (a NUL in a raw struct's
  fields, say) returns `{:error, changeset}` with a `:base` error, like a
  failed validation; the bang versions raise as usual.
  """

  use Ecto.Repo, otp_app: :firefly, adapter: Ecto.Adapters.Postgres
  use Scrivener, page_size: 10

  alias Firefly.Text

  @unstorable "contains characters that can't be stored"

  defoverridable insert: 1,
                 insert: 2,
                 update: 1,
                 update: 2,
                 insert_or_update: 1,
                 insert_or_update: 2,
                 insert!: 1,
                 insert!: 2,
                 update!: 1,
                 update!: 2,
                 insert_or_update!: 1,
                 insert_or_update!: 2

  def insert(struct, opts \\ []) do
    super(Text.strip_nul_changes(struct), opts)
  rescue
    error in Postgrex.Error -> refused(error, struct, :insert, __STACKTRACE__)
  end

  def update(changeset, opts \\ []) do
    super(Text.strip_nul_changes(changeset), opts)
  rescue
    error in Postgrex.Error -> refused(error, changeset, :update, __STACKTRACE__)
  end

  def insert_or_update(changeset, opts \\ []) do
    super(Text.strip_nul_changes(changeset), opts)
  rescue
    error in Postgrex.Error -> refused(error, changeset, :insert_or_update, __STACKTRACE__)
  end

  def insert!(struct, opts \\ []), do: super(Text.strip_nul_changes(struct), opts)
  def update!(changeset, opts \\ []), do: super(Text.strip_nul_changes(changeset), opts)

  def insert_or_update!(changeset, opts \\ []),
    do: super(Text.strip_nul_changes(changeset), opts)

  defp refused(error, struct_or_changeset, action, stacktrace) do
    if Text.unstorable?(error) do
      changeset = Ecto.Changeset.change(struct_or_changeset)
      {:error, %{Ecto.Changeset.add_error(changeset, :base, @unstorable) | action: action}}
    else
      reraise error, stacktrace
    end
  end
end
