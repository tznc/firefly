defmodule Firefly.TextTest do
  use Firefly.DataCase, async: true

  import Firefly.Fixtures

  alias Firefly.{Discussion, Repo, Text}
  alias Firefly.Discussion.{Category, Search}

  doctest Firefly.Text

  describe "strip_nul/1" do
    test "strips NUL from strings, nested in maps, lists and keyword lists" do
      input = %{
        <<"ke", 0, "y">> => [<<"a", 0>>, %{"deep" => <<0, 0, "b">>}],
        "opts" => [title: <<"t", 0>>, count: 3],
        "n" => 1
      }

      assert Text.strip_nul(input) == %{
               "key" => ["a", %{"deep" => "b"}],
               "opts" => [title: "t", count: 3],
               "n" => 1
             }
    end

    test "leaves other terms as they are" do
      at = ~U[2026-01-01 00:00:00Z]
      upload = %Plug.Upload{filename: <<"a", 0>>}

      for term <- [nil, 1, 1.5, :atom, {<<0>>}, at, upload, ~c"ab", [1 | "x"]],
          do: assert(Text.strip_nul(term) == term)

      assert Text.strip_nul("plain") == "plain"
      assert Text.strip_nul(<<0xFF, 0>>) == <<0xFF>>
    end
  end

  describe "strip_nul_changes/1 and Firefly.Changeset.cast/4" do
    defmodule Holder do
      use Ecto.Schema

      embedded_schema do
        field(:title, :string)
        field(:data, :map)
        field(:tags, {:array, :string})
        field(:secret, :binary)

        embeds_many(:items, Item) do
          field(:name, :string)
        end
      end
    end

    test "strips text, map and array changes, nested changesets too, never binaries" do
      changeset =
        %Holder{}
        |> Firefly.Changeset.cast(
          %{
            title: <<"a", 0>>,
            data: %{"k" => <<0, "v">>},
            tags: [<<"t", 0>>],
            secret: <<1, 0, 2>>,
            items: [%{name: <<"n", 0>>}]
          },
          [:title, :data, :tags, :secret]
        )
        |> Ecto.Changeset.cast_embed(:items, with: &Ecto.Changeset.cast(&1, &2, [:name]))
        |> Text.strip_nul_changes()

      assert %{title: "a", data: %{"k" => "v"}, tags: ["t"], secret: <<1, 0, 2>>} =
               changeset.changes

      assert [%{changes: %{name: "n"}}] = changeset.changes.items
    end
  end

  describe "writing through the repo" do
    # Was a :pending test of the property stack: a NUL in user text raised.
    test "a category's title is saved without the NUL" do
      assert {:ok, category} = Discussion.create_category(%{title: <<"a", 0>>})
      assert category.title == "a"
      assert Repo.get!(Category, category.id).title == "a"
    end

    test "a post's body and a thread's title are saved without the NUL" do
      user = user_fixture()
      category = category_fixture()

      assert {:ok, thread} =
               Discussion.create_thread(category, user, %{
                 title: <<"Hello ", 0, "there">>,
                 body: <<"Body", 0, " text">>
               })

      thread = Repo.preload(thread, :posts, force: true)
      assert thread.title == "Hello there"
      assert [%{body: "Body text"}] = thread.posts
    end

    # Found by Firefly.BadgesPropertyTest: a badge granted with a reason
    # holding NUL went in as a raw struct and Postgres refused it.
    test "a raw struct's text is saved without the NUL" do
      category = Repo.insert!(%Category{title: <<"raw", 0>>, slug: "raw-struct"})
      assert Repo.get!(Category, category.id).title == "raw"
    end

    # The backstop: text Postgres still can't store (bytes that aren't UTF-8)
    # reaches it, it refuses it, and the repo turns that into an error result.
    test "Postgres refuses unstorable text, and the repo returns an error" do
      assert {:error, changeset} = Repo.insert(%Category{title: <<"raw", 0xFF>>})
      assert {"contains characters that can't be stored", []} = changeset.errors[:base]
      assert changeset.action == :insert

      error =
        assert_raise Postgrex.Error, fn -> Repo.insert!(%Category{title: <<"raw", 0xFF>>}) end

      assert Text.unstorable?(error)

      # jsonb refuses "\u0000" with its own code.
      error =
        assert_raise Postgrex.Error, fn ->
          Repo.query!("SELECT '\"\\u0000\"'::jsonb")
        end

      assert Text.unstorable?(error)
      refute Text.unstorable?(%RuntimeError{})

      # The sandbox's transaction is still usable afterwards.
      assert {:ok, _} = Discussion.create_category(%{title: "fine"})
    end
  end

  test "search strips NUL from the query and its controls" do
    search = Search.parse(<<"elixir", 0, " tag:otp", 0>>, %{"user" => <<"bob", 0>>})
    assert {search.terms, search.tag, search.user} == {"elixir", "otp", "bob"}
    assert %{} = Search.run(search, nil)
  end
end
