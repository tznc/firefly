defmodule Firefly.DirectorySearchTest do
  @moduledoc "Regression tests for searches Firefly.DirectoryPropertyTest found mishandled."
  use Firefly.DataCase, async: true

  import Firefly.Fixtures

  alias Firefly.Directory

  # Postgres refused a search holding NUL or invalid UTF-8, and the public
  # directory page raised; they're dropped from the search now.
  test "a search with NUL or invalid UTF-8 searches the rest of it" do
    user_fixture(%{username: "nulsearch"})

    for name <- [<<"nulse", 0, "arch">>, <<"nulsearch", 0xFF>>] do
      assert [%{user: %{username: "nulsearch"}}] = Directory.page(%{"name" => name}).entries
    end

    assert is_list(Directory.page(%{"name" => <<0>>}).entries)
  end
end
