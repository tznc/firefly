defmodule Firefly.Fixtures do
  @moduledoc """
  Test data shared by every app's tests (`import Firefly.Fixtures`; web
  tests get it through `FireflyWeb.ConnCase`).
  """

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
      |> Firefly.Forums.create_user()

    user
  end

  @doc "Creates a user with the admin role."
  def admin_fixture(attrs \\ %{}) do
    user = user_fixture(attrs)

    role =
      Firefly.Repo.get_by(Firefly.Forums.Role, name: "admin") ||
        elem(Firefly.Forums.create_role("admin"), 1)

    {:ok, _} = Firefly.Forums.add_role(user, role)
    user
  end

  @doc "Creates a category."
  def category_fixture(title \\ "Elixir") do
    {:ok, category} = Firefly.Forums.create_category(%{title: title})
    category
  end

  @doc "Creates a thread (with its first post) in `category` by `user`."
  def thread_fixture(category, user, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{title: "OTP is cool", body: "Don't you think?"})
    {:ok, thread} = Firefly.Forums.create_thread(category, user, attrs)
    thread
  end
end
