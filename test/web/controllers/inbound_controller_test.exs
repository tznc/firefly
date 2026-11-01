defmodule FirestormWeb.InboundControllerTest do
  use FirestormWeb.Web.ConnCase

  alias FirestormWeb.{Forums, Repo, ReplyAddress}

  setup do
    user = user_fixture(%{username: "knewter", email: "josh@example.com"})
    category = category_fixture()
    thread = thread_fixture(category, user)
    {:ok, user: user, thread: thread}
  end

  defp inbound(conn, params, token \\ "test-inbound-token") do
    post(conn, "/inbound/sendgrid?token=#{token}", params)
  end

  defp email(to, from, text \\ "this is the text body") do
    %{"to" => to, "from" => from, "text" => text, "subject" => "Re: thread"}
  end

  defp last_post_body(thread) do
    thread
    |> Repo.preload(:posts, force: true)
    |> Map.fetch!(:posts)
    |> List.last()
    |> Map.fetch!(:body)
  end

  test "posts a reply sent to the user's signed reply address", %{
    conn: conn,
    user: user,
    thread: thread
  } do
    to = ReplyAddress.address(thread, user)
    conn = inbound(conn, email(to, "Josh Adams <josh@example.com>"))

    assert response(conn, 200) =~ "ok"
    assert last_post_body(thread) == "this is the text body"
  end

  test "accepts the address among several recipients and in any case", %{
    conn: conn,
    user: user,
    thread: thread
  } do
    to = "someone@example.com, " <> String.upcase(ReplyAddress.address(thread, user))
    inbound(conn, email(to, "JOSH@EXAMPLE.COM"))

    assert last_post_body(thread) == "this is the text body"
  end

  test "ignores a forged From header", %{conn: conn, user: user, thread: thread} do
    to = ReplyAddress.address(thread, user)
    conn = inbound(conn, email(to, "Mallory <mallory@example.com>"))

    assert response(conn, 200)
    assert last_post_body(thread) == "Don't you think?"
  end

  test "ignores unsigned or tampered reply addresses", %{conn: conn, user: user, thread: thread} do
    other = user_fixture(%{email: "other@example.com"})
    domain = ReplyAddress.domain()
    valid = ReplyAddress.address(thread, user)
    [_, sig] = Regex.run(~r/-([a-z2-7]+)@/, valid)

    for to <- [
          "reply-thread-#{thread.id}@#{domain}",
          "reply+#{thread.id}-#{user.id}-aaaaaaaaaaaaaaaaaaaaaaaa@#{domain}",
          # user's valid signature reused for another user
          "reply+#{thread.id}-#{other.id}-#{sig}@#{domain}",
          String.replace(valid, domain, "evil.example.com")
        ] do
      inbound(conn, email(to, "other@example.com"))
      inbound(conn, email(to, "josh@example.com"))
    end

    assert last_post_body(thread) == "Don't you think?"
  end

  test "rejects requests without the webhook token", %{conn: conn, user: user, thread: thread} do
    to = ReplyAddress.address(thread, user)

    assert conn |> inbound(email(to, "josh@example.com"), "wrong") |> response(403)
    assert conn |> post("/inbound/sendgrid", email(to, "josh@example.com")) |> response(403)
    assert last_post_body(thread) == "Don't you think?"
  end

  test "is disabled when no webhook token is configured", %{
    conn: conn,
    user: user,
    thread: thread
  } do
    config = Application.fetch_env!(:firestorm_web, :email)
    Application.put_env(:firestorm_web, :email, Keyword.put(config, :inbound_token, nil))
    on_exit(fn -> Application.put_env(:firestorm_web, :email, config) end)

    to = ReplyAddress.address(thread, user)
    assert conn |> inbound(email(to, "josh@example.com")) |> response(404)
  end

  test "ignores replies to deleted threads", %{conn: conn, user: user, thread: thread} do
    to = ReplyAddress.address(thread, user)
    {:ok, _} = Forums.delete_thread(thread, user)

    assert conn |> inbound(email(to, "josh@example.com")) |> response(200)
  end
end
