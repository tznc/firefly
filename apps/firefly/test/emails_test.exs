defmodule Firefly.EmailsTest do
  use Firefly.DataCase

  alias Firefly.{Accounts, Discussion}
  alias Firefly.Notifications.{Emails, ReplyAddress}

  test "notification emails come from Firefly with a signed per-user reply address" do
    {:ok, user} = Accounts.create_user(%{username: "u", name: "U", email: "u@example.com"})
    {:ok, category} = Discussion.create_category(%{title: "Elixir"})
    {:ok, thread} = Discussion.create_thread(category, user, %{title: "T", body: "B"})
    [post] = Repo.preload(thread, :posts).posts

    email = Emails.thread_new_post_notification(user, thread, post)

    assert email.from == {"Firefly", "noreply@firefly.tznc.dev"}
    assert {"", reply_to} = email.reply_to
    assert reply_to == ReplyAddress.address(thread, user)
    assert email.html_body =~ "/categories/#{category.id}/threads/#{thread.id}"
    assert {:ok, thread_id, user_id} = ReplyAddress.verify(reply_to)
    assert {thread_id, user_id} == {thread.id, user.id}
  end

  test "an account without an address gets an email without a recipient" do
    {_template, email} = List.keyfind(Emails.previews(), "test_email", 0)
    assert %{to: [{"", _}]} = email
    assert Emails.test_email(nil).to == []
  end

  describe "headers survive every adapter" do
    # The digest's one-click unsubscribe, a notification's reply address and
    # mailing list mode's list id.
    setup do
      previews = Map.new(Emails.previews())

      email =
        previews["digest"]
        |> Swoosh.Email.reply_to(previews["mailing_list_post"].reply_to)
        |> Swoosh.Email.header("List-Id", previews["mailing_list_post"].headers["List-Id"])

      %{email: email, reply_to: elem(email.reply_to, 1)}
    end

    defmodule Provider do
      @moduledoc false
      @behaviour Plug

      @ses_answer """
      <SendRawEmailResponse xmlns="http://ses.amazonaws.com/doc/2010-12-01/">
        <SendRawEmailResult><MessageId>1</MessageId></SendRawEmailResult>
        <ResponseMetadata><RequestId>1</RequestId></ResponseMetadata>
      </SendRawEmailResponse>
      """

      def init(test), do: test

      def call(conn, test) do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:request, conn.request_path, body})

        # SES answers XML at /, the others JSON.
        {type, answer} =
          if conn.request_path == "/",
            do: {"text/xml", @ses_answer},
            else: {"application/json", ~s({"id": "1", "MessageID": "1", "message_id": "1"})}

        conn
        |> Plug.Conn.put_resp_content_type(type)
        |> Plug.Conn.send_resp(200, answer)
      end
    end

    defp provider do
      pid = start_supervised!({Bandit, plug: {Provider, self()}, port: 0, ip: :loopback})
      {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
      "http://127.0.0.1:#{port}"
    end

    defp assert_mime_headers(mime, reply_to) do
      assert mime =~ "Reply-To: #{reply_to}"
      assert mime =~ ~r/List-Unsubscribe: <http[^>]+>/
      assert mime =~ "List-Unsubscribe-Post: List-Unsubscribe=One-Click"
      assert mime =~ "List-Id: Firefly <list."
    end

    test "SMTP's message", %{email: email, reply_to: reply_to} do
      email |> Swoosh.Adapters.SMTP.Helpers.body([]) |> assert_mime_headers(reply_to)
    end

    test "Amazon SES's raw message", %{email: email, reply_to: reply_to} do
      config = [region: "eu-west-1", access_key: "AKID", secret: "secret", host: provider()]
      assert {:ok, _} = Swoosh.Adapters.AmazonSES.deliver(email, config)

      assert_received {:request, "/", body}
      raw = URI.decode_query(body)["RawMessage.Data"]
      raw |> Base.decode64!() |> assert_mime_headers(reply_to)
    end

    test "SendGrid's JSON", %{email: email, reply_to: reply_to} do
      assert {:ok, _} =
               Swoosh.Adapters.Sendgrid.deliver(email, api_key: "k", base_url: provider())

      assert_received {:request, "/mail/send", body}
      body = Jason.decode!(body)
      assert body["reply_to"] == %{"email" => reply_to}
      assert body["headers"]["List-Unsubscribe"] =~ ~r/^<http[^>]+>$/
      assert body["headers"]["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
      assert body["headers"]["List-Id"] =~ "Firefly <list."
    end

    test "Mailgun's form", %{email: email, reply_to: reply_to} do
      config = [api_key: "k", domain: "mg.example.com", base_url: provider()]
      assert {:ok, _} = Swoosh.Adapters.Mailgun.deliver(email, config)

      assert_received {:request, "/mg.example.com/messages", body}
      form = URI.decode_query(body)
      assert form["h:Reply-To"] == reply_to
      assert form["h:List-Unsubscribe"] =~ ~r/^<http[^>]+>$/
      assert form["h:List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
      assert form["h:List-Id"] =~ "Firefly <list."
    end

    test "Postmark's JSON", %{email: email, reply_to: reply_to} do
      assert {:ok, _} =
               Swoosh.Adapters.Postmark.deliver(email, api_key: "k", base_url: provider())

      assert_received {:request, "/email", body}
      body = Jason.decode!(body)
      assert body["ReplyTo"] == reply_to
      headers = Map.new(body["Headers"], &{&1["Name"], &1["Value"]})
      assert headers["List-Unsubscribe"] =~ ~r/^<http[^>]+>$/
      assert headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
      assert headers["List-Id"] =~ "Firefly <list."
    end
  end
end
