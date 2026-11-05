defmodule Firefly.NulPropertyTest do
  @moduledoc """
  Text with NUL characters (which Postgres can't store) through the main
  create paths, straight into the domain: none of them raises, and nothing
  stored keeps a NUL.
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.{Discussion, Repo, SiteSettings, Themes}
  alias Firefly.Discussion.{Post, Search}
  alias Firefly.Plugin.Settings

  # Words, punctuation and spaces with NULs mixed in (valid UTF-8: the web
  # refuses anything else before it gets here).
  defp nul_text do
    [
      string(:alphanumeric, min_length: 1, max_length: 8),
      member_of([" ", "\n", "-", "<p>", "*", "#"]),
      constant(<<0>>),
      constant("\u0000")
    ]
    |> one_of()
    |> list_of(min_length: 1, max_length: 12)
    |> map(&Enum.join/1)
  end

  defp nul_free?(text) when is_binary(text), do: :binary.match(text, <<0>>) == :nomatch
  defp nul_free?(%_{} = struct), do: struct |> Map.from_struct() |> nul_free?()

  defp nul_free?(map) when is_map(map),
    do: Enum.all?(map, fn {k, v} -> nul_free?(k) and nul_free?(v) end)

  defp nul_free?(list) when is_list(list), do: Enum.all?(list, &nul_free?/1)
  defp nul_free?(_other), do: true

  setup do
    admin = admin_fixture()
    %{admin: admin, member: user_fixture(), category: category_fixture()}
  end

  # A title starts with a letter: one that slugifies to nothing (just "-")
  # fails in the slug lookup, with or without a NUL.
  property "categories, threads and posts are stored without NUL", ctx do
    check all(
            title <- map(nul_text(), &("t" <> &1)),
            body <- nul_text(),
            max_runs: runs(40)
          ) do
      case Discussion.create_category(%{title: title, description: body}) do
        {:ok, category} -> assert nul_free?(Repo.reload!(category))
        {:error, %Ecto.Changeset{}} -> :ok
      end

      case Discussion.create_thread(ctx.category, ctx.member, %{title: title, body: body}) do
        {:ok, thread} ->
          thread = Repo.preload(Repo.reload!(thread), :posts)
          assert nul_free?(thread)

          case Discussion.create_post(thread, ctx.member, %{body: body <> " reply"}) do
            {:ok, post} -> assert nul_free?(Repo.get!(Post, post.id).body)
            {:error, _reason} -> :ok
          end

        {:error, _reason} ->
          :ok
      end
    end
  end

  property "site settings and plugin settings are stored without NUL", ctx do
    check all(text <- nul_text(), max_runs: runs(40)) do
      case SiteSettings.update(%{"description" => text}, ctx.admin) do
        {:ok, _changes} -> assert nul_free?(SiteSettings.get("description"))
        {:error, _errors} -> :ok
      end

      case Settings.cast(%{type: "text"}, text) do
        {:ok, value} -> assert nul_free?(value)
        {:error, _message} -> :ok
      end
    end
  end

  property "themes are stored without NUL", ctx do
    check all(name <- nul_text(), html <- nul_text(), max_runs: runs(30)) do
      attrs = %{"name" => name, "head_html" => html, "css" => html, "description" => html}

      case Themes.create_theme(attrs, ctx.admin) do
        {:ok, theme} -> assert nul_free?(Repo.reload!(theme))
        {:error, %Ecto.Changeset{}} -> :ok
      end
    end
  end

  property "search never raises", ctx do
    check all(query <- nul_text(), user <- nul_text(), max_runs: runs(40)) do
      search = Search.parse(query, %{"user" => user, "category" => user})
      assert nul_free?(search)
      assert Search.run(search, ctx.member)
    end
  end
end
