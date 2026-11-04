defmodule Firefly.AccountsPropertyTest do
  @moduledoc """
  Properties of `Firefly.Accounts`: registration validates without
  crashing, only the password set logs in, case-insensitive lookups agree
  with each other, and signed tokens (password reset, email
  confirmation, API keys) round-trip and refuse anything altered.
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.Accounts
  alias Firefly.Accounts.{ApiKeys, EmailConfirmation, PasswordReset, User}

  # Generated names get a unique suffix: runs share the test's database.
  defp unique(name), do: "#{name}#{System.unique_integer([:positive])}"

  defp register(username, password, email \\ nil) do
    Accounts.register_user(%{
      "username" => username,
      "email" => email || "#{String.downcase(username)}@example.com",
      "password" => password
    })
  end

  describe "registration" do
    property "never raises, whatever the fields hold" do
      check all(
              username <- one_of([username(), any_text()]),
              email <- one_of([email(), any_text()]),
              password <- one_of([password(), any_text(), long_string(500)]),
              max_runs: runs(100)
            ) do
        changeset =
          User.registration_changeset(%User{}, %{
            username: username,
            email: email,
            password: password
          })

        assert %Ecto.Changeset{} = changeset

        if changeset.valid? do
          assert changeset.changes.username =~ ~r/\A[A-Za-z0-9_-]+\z/
          assert is_binary(changeset.changes.password_hash)
        end
      end
    end

    property "only the password set logs in" do
      check all(
              name <- username(),
              password <- password(),
              other <- password(),
              max_runs: runs(15)
            ) do
        name = unique(name)
        assert {:ok, user} = register(name, password)
        assert {:ok, %User{id: id}} = Accounts.authenticate_by_password(name, password)
        assert id == user.id

        if other != password,
          do: assert({:error, _} = Accounts.authenticate_by_password(name, other))

        assert {:error, _} = Accounts.authenticate_by_password(name <> "x", password)
      end
    end

    property "passwords are measured in bytes, as bcrypt reads them" do
      check all(password <- password(1, 80), max_runs: runs(100)) do
        changeset =
          User.registration_changeset(%User{}, %{
            "username" => "someone",
            "email" => "someone@example.com",
            "password" => password
          })

        # bcrypt only reads the first 72 bytes: a longer password would
        # log in with any other that starts the same.
        if byte_size(password) > 72, do: refute(changeset.valid?)
      end
    end
  end

  describe "lookups" do
    property "usernames match in any case, the exact one first" do
      check all(name <- username(), max_runs: runs(15)) do
        name = unique(name)
        user = user_fixture(%{username: name})

        for variant <- [name, String.upcase(name), String.downcase(name)] do
          assert %{^variant => %User{id: id}} = Accounts.users_by_username([variant])
          assert id == user.id
          assert user.id in Enum.map(Accounts.search_usernames(variant, 50), & &1.id)
        end

        # A prefix in any case finds it too.
        prefix = String.slice(name, 0, 3)

        assert user.id in Enum.map(
                 Accounts.search_usernames(String.upcase(prefix), 1_000),
                 & &1.id
               )
      end
    end

    property "search never raises, LIKE wildcards are literal" do
      check all(
              prefix <- one_of([adversarial_text(5), member_of(["%", "_", "\\", "%_", "a%"])]),
              max_runs: runs(100)
            ) do
        users = Accounts.search_usernames(prefix)
        lower = String.downcase(prefix)
        assert Enum.all?(users, &String.starts_with?(String.downcase(&1.username), lower))
      end
    end

    property "emails match for login help in any case and with spaces around" do
      check all(name <- username(), max_runs: runs(15)) do
        name = unique(name)
        email = "#{name}@Example.com"
        assert {:ok, user} = register(name, "a long password", email)

        for variant <- [email, String.upcase(email), "  " <> String.downcase(email) <> " "] do
          assert user.id in Enum.map(Accounts.list_password_users_by_email(variant), & &1.id)
        end
      end
    end

    property "reserved names are reserved in any case" do
      {:ok, _} =
        Firefly.SiteSettings.update(
          %{"reserved_usernames" => "admin,Staff,support-team"},
          admin_fixture()
        )

      check all(
              reserved <- member_of(Firefly.SiteSettings.get("reserved_usernames")),
              max_runs: runs(30)
            ) do
        for variant <- [reserved, String.upcase(reserved), String.capitalize(reserved)] do
          assert User.reserved_username?(variant)
          refute User.changeset(%User{}, %{username: variant, name: "x"}).valid?
        end
      end
    end
  end

  describe "tokens" do
    property "password reset and confirmation tokens round-trip, and refuse alterations" do
      check all(
              flips <- list_of(integer(0..10_000), min_length: 1, max_length: 3),
              junk <- any_text(),
              max_runs: runs(20)
            ) do
        user = user_fixture(%{username: unique("tok")})
        {:ok, user} = Accounts.update_user(user, %{email: "#{user.username}@example.com"})
        reset = PasswordReset.token(user)
        assert {:ok, %User{id: id}} = PasswordReset.verify(reset)
        assert id == user.id

        for token <- [reset, EmailConfirmation.token(user)],
            altered <- [alter(token, flips), token <> "x", junk, String.reverse(token)],
            altered != token do
          assert {:error, :invalid} = PasswordReset.verify(altered)
          assert {:error, :invalid} = EmailConfirmation.confirm(altered)
        end

        assert {:ok, _} = EmailConfirmation.confirm(EmailConfirmation.token(user))
      end
    end

    property "API keys authenticate exactly their token" do
      check all(
              flips <- list_of(integer(0..10_000), min_length: 1, max_length: 3),
              junk <- any_text(),
              max_runs: runs(15)
            ) do
        user = user_fixture(%{username: unique("key")})
        token = api_token(user)
        assert {:ok, _key, %User{id: id}} = ApiKeys.authenticate(token, {127, 0, 0, 1})
        assert id == user.id

        for altered <- [alter(token, flips), junk, token <> "x", ""], altered != token do
          assert {:error, _} = ApiKeys.authenticate(altered, {127, 0, 0, 1})
        end
      end
    end
  end

  # `token` with the characters at `positions` changed to others of its alphabet.
  defp alter(token, positions) do
    chars = String.graphemes(token)

    positions
    |> Enum.reduce(chars, fn at, chars ->
      at = rem(at, length(chars))
      List.update_at(chars, at, fn c -> if c == "A", do: "B", else: "A" end)
    end)
    |> Enum.join()
  end

  describe "deep fuzzing" do
    @describetag :fuzz
    @describetag timeout: :infinity

    property "registration validation stays total" do
      check all(
              username <- one_of([username(), any_text(), long_string(1_000)]),
              email <- one_of([email(), any_text()]),
              password <- one_of([password(), any_text()]),
              max_runs: fuzz_runs()
            ) do
        assert %Ecto.Changeset{} =
                 User.registration_changeset(%User{}, %{
                   username: username,
                   email: email,
                   password: password
                 })
      end
    end
  end
end
