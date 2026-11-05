defmodule Firefly.AccountsInputsTest do
  @moduledoc "Regression tests for inputs Firefly.AccountsPropertyTest found mishandled."
  use Firefly.DataCase, async: true

  import Firefly.Fixtures

  alias Firefly.Accounts
  alias Firefly.Accounts.User

  defp register(password) do
    Accounts.register_user(%{
      "username" => "brie#{System.unique_integer([:positive])}",
      "email" => "brie#{System.unique_integer([:positive])}@example.com",
      "password" => password
    })
  end

  # bcrypt reads only the first 72 bytes: a 72-character password of
  # multibyte characters let in any other that shared those bytes.
  test "passwords are at most 72 bytes, not 72 characters" do
    shared = String.duplicate("é", 36)
    assert byte_size(shared) == 72

    assert {:error, changeset} = register(shared <> "secret")

    assert "should be at most 72 bytes (fewer characters with accents or emoji)" in errors_on(
             changeset
           ).password

    assert {:ok, user} = register(shared)
    assert {:ok, _} = Accounts.authenticate_by_password(user.username, shared)

    refute User.password_changeset(user, %{"password" => shared <> "x"}).valid?
  end

  # Form posts can send bytes that aren't UTF-8; measuring them raised.
  test "fields that aren't UTF-8 are errors, not crashes" do
    changeset =
      User.registration_changeset(%User{}, %{
        "username" => "brie",
        "email" => <<"a", 0xFF, "@example.com">>,
        "password" => <<"pass", 0xC3, "word">>
      })

    refute changeset.valid?
    assert "isn't valid text" in errors_on(changeset).email
    assert "isn't valid text" in errors_on(changeset).password

    refute User.password_changeset(%User{}, %{"password" => <<0xFF, "long enough">>}).valid?
  end

  # Postgres refuses NUL and invalid UTF-8 in a query: the @-autocomplete
  # raised.
  test "username search with a prefix Postgres can't take finds nobody" do
    user_fixture(%{username: "brie"})
    assert Accounts.search_usernames(<<"b", 0>>) == []
    assert Accounts.search_usernames(<<"b", 0xFF>>) == []
    assert [%User{username: "brie"}] = Accounts.search_usernames("BR")
  end
end
