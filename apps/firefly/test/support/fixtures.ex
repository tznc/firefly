defmodule Firefly.Fixtures do
  @moduledoc """
  Test data shared by every app's tests (`import Firefly.Fixtures`; web
  tests get it through `FireflyWeb.ConnCase`).
  """

  # Test support, for any app's tests: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]

  @doc "Creates a user with sensible defaults."
  def user_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      attrs
      |> Enum.into(%{
        username: "user#{unique}",
        email: "user#{unique}@example.com",
        name: "User #{unique}"
      })
      |> Firefly.Accounts.create_user()

    user
  end

  @doc "Creates a user with the admin role."
  def admin_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)

    role =
      Firefly.Repo.get_by(Firefly.Groups.Role, name: "admin") ||
        elem(Firefly.Groups.create_role("admin"), 1)

    {:ok, _} = Firefly.Groups.add_role(user, role)
    user
  end

  @doc "Creates a category."
  def category_fixture(title \\ "Elixir") do
    {:ok, category} = Firefly.Discussion.create_category(%{title: title})
    category
  end

  @doc "Creates a thread (with its first post) in `category` by `user`."
  def thread_fixture(category, user, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{title: "OTP is cool", body: "Don't you think?"})
    {:ok, thread} = Firefly.Discussion.create_thread(category, user, attrs)
    thread
  end
end
