defmodule FirestormWeb.Forums.PolicyTest do
  use FirestormWeb.DataCase

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.{Policy, User}

  @alice %User{id: 1}
  @bob %User{id: 2}

  describe ":edit_user" do
    test "when current_user is some other user" do
      assert {:error, :unauthorized} = Policy.authorize(:edit_user, @alice, %{user: @bob})
    end

    test "when current_user is the user in question" do
      assert :ok = Policy.authorize(:edit_user, @alice, %{user: @alice})
    end

    test "when current_user is nil" do
      assert {:error, :unauthenticated} = Policy.authorize(:edit_user, nil, %{user: @bob})
    end
  end

  setup do
    {:ok, author} = Forums.create_user(%{username: "author", name: "A", email: "a@example.com"})
    {:ok, member} = Forums.create_user(%{username: "member", name: "M", email: "m@example.com"})
    {:ok, admin} = Forums.create_user(%{username: "admin", name: "Ad", email: "ad@example.com"})
    {:ok, role} = Forums.create_role("admin")
    {:ok, _} = Forums.add_role(admin, role)
    {:ok, category} = Forums.create_category(%{title: "Elixir"})
    {:ok, thread} = Forums.create_thread(category, author, %{title: "T", body: "B"})
    {:ok, _} = Forums.create_post(thread, member, %{body: "reply"})

    {:ok, author: author, member: member, admin: admin, thread: thread}
  end

  test ":manage_category is for admins", %{member: member, admin: admin} do
    assert :ok = Policy.authorize(:manage_category, admin, %{})
    assert {:error, :unauthorized} = Policy.authorize(:manage_category, member, %{})
    assert {:error, :unauthenticated} = Policy.authorize(:manage_category, nil, %{})
  end

  test "threads can be changed by their author and admins", ctx do
    for action <- [:update_thread, :delete_thread] do
      assert :ok = Policy.authorize(action, ctx.author, ctx.thread)
      assert :ok = Policy.authorize(action, ctx.admin, ctx.thread)
      # Replying to a thread doesn't make you its author
      assert {:error, :unauthorized} = Policy.authorize(action, ctx.member, ctx.thread)
      assert {:error, :unauthenticated} = Policy.authorize(action, nil, ctx.thread)
    end
  end
end
