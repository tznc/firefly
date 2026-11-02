defmodule FirestormWeb.E2E.PluginsTest do
  use FirestormWeb.E2ECase, async: false

  import FirestormWeb.PluginHelpers

  alias FirestormWeb.Forums
  alias FirestormWeb.Plugins.Storage

  test "the example plugin: shortcode, widget bridge, composer button and page", %{conn: conn} do
    admin = admin_fixture("alice")
    install_example!(admin, "hello")
    {:ok, category} = Forums.create_category(%{title: "Elixir"})

    {:ok, thread} =
      Forums.create_thread(category, admin, %{title: "Greetings", body: ~s([hello name="World"])})

    conn
    |> log_in("alice")
    |> visit("/categories/#{category.id}/threads/#{thread.id}")
    |> assert_has(".hello", text: "Hello, World!")
    # The sandboxed widget loaded, got its context over postMessage, called
    # the plugin's handler through the LiveView and asked to be resized.
    |> assert_has("[phx-hook='PluginWidget'][data-ready='true'][data-height='48']")
    |> visit("/categories/#{category.id}/threads/#{thread.id}/posts/new")
    |> assert_has("[data-phx-main].phx-connected")
    |> fill_in("Body", with: "Ann")
    |> click_button("Hello")
    |> assert_has("textarea", value: ~s(Ann[hello name=""]))
    |> visit("/plugins/hello")
    |> assert_has(".plugin-view", text: "Widget views: 1")

    assert Storage.get("hello", "views") == 1
  end
end
