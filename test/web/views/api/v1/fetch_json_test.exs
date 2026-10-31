defmodule FirestormWeb.Web.Api.V1.FetchJSONTest do
  use FirestormWeb.Web.ConnCase, async: true
  alias FirestormWeb.Web.Api.V1.{FetchJSON, CategoryJSON, ThreadJSON, PostJSON, UserJSON}
  alias FirestormWeb.Store.ReplenishResponse
  alias FirestormWeb.Forums

  test "rendering an empty ReplenishResponse successfully" do
    result = FetchJSON.index(%ReplenishResponse{})
    assert %{categories: [], users: [], threads: [], posts: []} == result
  end

  test "rendering a ReplenishResponse with a category" do
    {:ok, elixir} = Forums.create_category(%{title: "Elixir"})
    result = FetchJSON.index(%ReplenishResponse{categories: [elixir]})
    elixir_json = CategoryJSON.data(elixir)
    assert %{categories: [elixir_json], users: [], threads: [], posts: []} == result
  end

  test "rendering a ReplenishResponse with a thread" do
    {:ok, elixir} = Forums.create_category(%{title: "Elixir"})

    {:ok, bob} =
      Forums.create_user(%{email: "bob@example.com", name: "Bob Vladbob", username: "bob"})

    {:ok, otp_is_cool} =
      Forums.create_thread(elixir, bob, %{title: "OTP is cool", body: "Don't you think?"})

    result = FetchJSON.index(%ReplenishResponse{threads: [otp_is_cool]})
    otp_is_cool_json = ThreadJSON.data(otp_is_cool)
    assert %{categories: [], users: [], threads: [otp_is_cool_json], posts: []} == result
  end

  test "rendering a ReplenishResponse with a post" do
    {:ok, elixir} = Forums.create_category(%{title: "Elixir"})

    {:ok, bob} =
      Forums.create_user(%{email: "bob@example.com", name: "Bob Vladbob", username: "bob"})

    {:ok, otp_is_cool} =
      Forums.create_thread(elixir, bob, %{title: "OTP is cool", body: "Don't you think?"})

    {:ok, yup} = Forums.create_post(otp_is_cool, bob, %{body: "Yup"})
    result = FetchJSON.index(%ReplenishResponse{posts: [yup]})
    yup_json = PostJSON.data(yup)
    assert %{categories: [], users: [], threads: [], posts: [yup_json]} == result
  end

  test "rendering a ReplenishResponse with a user" do
    {:ok, bob} =
      Forums.create_user(%{email: "bob@example.com", name: "Bob Vladbob", username: "bob"})

    result = FetchJSON.index(%ReplenishResponse{users: [bob]})
    bob_json = UserJSON.data(bob)
    assert %{categories: [], users: [bob_json], threads: [], posts: []} == result
  end
end
