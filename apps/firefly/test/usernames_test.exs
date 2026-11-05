defmodule Firefly.UsernamesTest do
  @moduledoc "Usernames and emails are unique in any case, and every lookup ignores case."
  use Firefly.DataCase

  import Firefly.Fixtures

  alias Firefly.{Accounts, Discussion, Notifications}
  alias Firefly.Accounts.{Auth, User}
  alias Firefly.Import.Writer

  defp register(username, email) do
    Accounts.register_user(%{username: username, email: email, password: "s3cret-password"})
  end

  describe "uniqueness" do
    test "registering a case-variant of a taken username is refused" do
      assert {:ok, alice} = register("Alice", "alice@example.com")
      assert alice.username == "Alice"

      assert {:error, changeset} = register("alice", "other@example.com")
      assert "has already been taken" in errors_on(changeset).username
    end

    test "the database refuses one too, whatever the changeset" do
      Repo.insert!(%User{username: "Alice", name: "Alice"})

      assert_raise Ecto.ConstraintError, ~r/forums_users_lower_username_index/, fn ->
        Repo.insert!(%User{username: "alice", name: "alice"})
      end
    end

    test "renaming to another member's name in another case is refused, one's own case isn't" do
      user_fixture(%{username: "Alice"})
      bob = user_fixture(%{username: "bob"})

      assert {:error, changeset} = Accounts.update_user(bob, %{username: "ALICE"})
      assert "has already been taken" in errors_on(changeset).username

      assert {:ok, %{username: "Bob"}} = Accounts.update_user(bob, %{username: "Bob"})
    end

    test "emails are unique in any case too; accounts without one don't collide" do
      user_fixture(%{email: "Ada@Example.com"})

      assert {:error, changeset} = register("ada", "ada@example.COM")
      assert "has already been taken" in errors_on(changeset).email

      assert_raise Ecto.ConstraintError, ~r/forums_users_lower_email_index/, fn ->
        Repo.insert!(%User{username: "ada2", name: "ada2", email: "ADA@example.com"})
      end

      assert {:ok, _} = Accounts.create_user(%{username: "a1", name: "a1", email: nil})
      assert {:ok, _} = Accounts.create_user(%{username: "a2", name: "a2", email: nil})
    end
  end

  describe "lookups resolve any case to the one account" do
    setup do
      {:ok, alice} = register("Alice", "Alice@Example.com")
      %{alice: alice}
    end

    test "by username, email, mentions and autocomplete", %{alice: %{id: id} = alice} do
      for name <- ~w(Alice alice ALICE) do
        assert %User{id: ^id} = Accounts.get_user_by_username(name)
        assert %{^name => %User{id: ^id}} = Accounts.users_by_username([name])
        assert [%User{id: ^id}] = Accounts.search_usernames(String.slice(name, 0, 3))
      end

      assert %User{id: ^id} = Accounts.get_user_by_email("alice@example.com")
      assert alice.email == "Alice@Example.com"
    end

    test "password login", %{alice: %{id: id}} do
      for name <- ~w(Alice alice ALICE) do
        assert {:ok, %User{id: ^id}} = Accounts.authenticate_by_password(name, "s3cret-password")
      end
    end

    test "new accounts from SSO and importers don't take a case-variant" do
      assert Auth.free_username(%{nickname: "ALICE"}, "oidc") == "ALICE-1"
      assert Writer.unique_username("aLiCe") == "aLiCe2"
    end

    test "mentioning @ALICE notifies alice", %{alice: alice} do
      author = user_fixture()
      {:ok, alice} = Accounts.confirm_user(alice)
      {:ok, category} = Discussion.create_category(%{title: "Elixir"})
      {:ok, thread} = Discussion.create_thread(category, author, %{title: "OTP", body: "Hi"})
      {:ok, _post} = Discussion.create_post(thread, author, %{body: "Thoughts @ALICE?"})
      run_notifications()

      assert [_] = Enum.filter(Notifications.notifications_for(alice), &(&1.kind == "mentioned"))
    end
  end
end
