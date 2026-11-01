defmodule FirestormWeb.Forums.SpamGuardTest do
  use FirestormWeb.DataCase, async: true

  alias FirestormWeb.{Forums, Repo}
  alias FirestormWeb.Forums.{SpamGuard, User}

  @links "see https://a.example and http://b.example and www.c.example"

  defp user(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Forums.create_user(%{username: "u#{unique}", name: "U", email: "u#{unique}@example.com"})

    user |> Ecto.Changeset.change(attrs) |> Repo.update!()
  end

  defp category, do: elem(Forums.create_category(%{title: "C"}), 1)

  test "counts links" do
    assert SpamGuard.link_count(@links) == 3
    assert SpamGuard.link_count("no links here") == 0
  end

  test "new accounts can't post more than two links" do
    user = user()
    assert SpamGuard.new_user?(user)

    assert {:error, changeset} =
             Forums.create_thread(category(), user, %{title: "Spam", body: @links})

    [post_changeset] = changeset.changes.posts
    assert "new accounts can include at most 2 links per post" in errors_on(post_changeset).body

    assert {:ok, thread} =
             Forums.create_thread(category(), user, %{
               title: "Fine",
               body: "one https://a.example"
             })

    assert {:error, changeset} = Forums.create_post(thread, user, %{body: @links})
    assert errors_on(changeset).body == ["new accounts can include at most 2 links per post"]
  end

  test "established accounts and admins aren't limited" do
    old = user(%{inserted_at: ~N[2020-01-01 00:00:00.000000]})
    {:ok, thread} = Forums.create_thread(category(), old, %{title: "1", body: "a"})
    for body <- ~w(b c), do: {:ok, _} = Forums.create_post(thread, old, %{body: body})

    refute SpamGuard.new_user?(old)
    assert {:ok, _} = Forums.create_post(thread, old, %{body: @links})

    admin = user()
    {:ok, role} = Forums.create_role("admin")
    {:ok, _} = Forums.add_role(admin, role)
    admin = Repo.get!(User, admin.id)

    refute SpamGuard.new_user?(admin)
    assert {:ok, _} = Forums.create_post(thread, admin, %{body: @links})
  end
end
