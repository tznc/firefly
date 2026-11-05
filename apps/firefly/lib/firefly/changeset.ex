defmodule Firefly.Changeset do
  @moduledoc """
  `Ecto.Changeset`, with a `cast/4` that strips NUL characters from what it
  casts to text, maps and arrays of text (see
  `Firefly.Text.strip_nul_changes/1`): PostgreSQL can't store them.

  Schemas and contexts `use Firefly.Changeset` in place of `import
  Ecto.Changeset`, so every changeset strips at its start, before
  validations and lookups (slugs, uniqueness) see the text, whether the call
  came from the web or straight from the domain. Fields of other types
  (`:binary` secrets and keys, which may hold NUL bytes) are cast as they
  are. `Firefly.Repo` strips again what was put into a changeset without
  casting.
  """

  defmacro __using__(_opts) do
    quote do
      import Ecto.Changeset, except: [cast: 3, cast: 4], warn: false
      import Firefly.Changeset, only: [cast: 3, cast: 4], warn: false
    end
  end

  @doc "`Ecto.Changeset.cast/4`, without NUL characters in text changes."
  @spec cast(
          Ecto.Schema.t() | Ecto.Changeset.t() | {Ecto.Changeset.data(), Ecto.Changeset.types()},
          map | :invalid,
          [atom],
          keyword
        ) :: Ecto.Changeset.t()
  def cast(data, params, permitted, opts \\ []) do
    data
    |> Ecto.Changeset.cast(params, permitted, opts)
    |> Firefly.Text.strip_nul_changes()
  end
end
