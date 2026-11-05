defmodule Firefly.DirectoryPropertyTest do
  @moduledoc """
  Properties of `Firefly.Directory.page/1`, which takes the directory
  page's URL parameters as they come: any period, order, direction,
  search and page number gives a page, never a crash, and a search only
  finds users whose username or name contains it (wildcards literal).
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.Directory

  defp param, do: one_of([any_text(), member_of(Firefly.Generators.numbers()), constant(nil)])

  property "any parameters give a page" do
    user_fixture(%{username: "percent_user"})

    check all(
            params <-
              optional_map(%{
                "period" => one_of([member_of(Directory.periods()), param()]),
                "order" => one_of([member_of(Directory.columns()), param()]),
                "asc" => member_of(["true", "false", "x"]),
                "name" => param(),
                "page" => param()
              }),
            max_runs: runs(200)
          ) do
      page = Directory.page(params)
      assert is_list(page.entries)

      if is_binary(params["name"]) and String.trim(params["name"]) != "" and
           String.valid?(params["name"]) do
        needle = params["name"] |> String.trim() |> String.downcase()

        for %{user: user} <- page.entries do
          assert String.contains?(String.downcase(user.username), needle) or
                   String.contains?(String.downcase(user.name || ""), needle)
        end
      end
    end
  end
end
