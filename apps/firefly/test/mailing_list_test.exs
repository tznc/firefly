defmodule Firefly.MailingListTest do
  use Firefly.DataCase
  import Swoosh.TestAssertions

  # Mail is sent from other processes (the notifications process, LiveViews).
  setup :set_swoosh_global

  alias Firefly.{Accounts, Discussion, Groups, Notifications, SiteSettings}
  alias Firefly.Accounts.Ignores
  alias Firefly.Notifications.{MailingList, ReplyAddress, Subscriptions}

  import Firefly.Fixtures

  setup do
    {:ok, _} = Notifications.start_link()
    category = category_fixture()
    author = user_fixture(%{username: "author", email: "author@example.com"})
    thread = thread_fixture(category, author, %{title: "Release plans"})
    flush()
    %{admin: admin_fixture(), category: category, author: author, thread: thread}
  end

  # Casts are async; a call to the server waits for them.
  defp flush, do: :sys.get_state(Notifications)

  defp lister(name, attrs \\ %{}) do
    user = user_fixture(Map.merge(%{username: name, email: "#{name}@example.com"}, attrs))
    {:ok, user} = Accounts.update_preferences(user, %{mailing_list_mode: true})
    user
  end

  defp reply(thread, user, body) do
    {:ok, post} = Discussion.create_post(thread, user, %{body: body})
    flush()
    post
  end

  test "every new thread and reply is emailed, with a reply address", ctx do
    lister = lister("lister")

    thread = thread_fixture(ctx.category, ctx.author, %{title: "Fresh"})
    flush()
    assert_email_sent(to: "lister@example.com", subject: "[Firefly] Fresh")

    reply(thread, ctx.author, "A reply")

    assert_receive {:email, email}
    assert email.text_body =~ "A reply"
    assert email.reply_to == {"", ReplyAddress.address(thread, lister)}
  end

  test "not one's own posts unless no echo is off", ctx do
    lister = lister("lister")
    reply(ctx.thread, lister, "Mine")
    refute_receive {:email, %{to: [{"", "lister@example.com"}]}}

    {:ok, _} = Accounts.update_preferences(lister, %{mailing_list_no_echo: false})
    reply(ctx.thread, lister, "Mine again")
    assert_receive {:email, %{to: [{"", "lister@example.com"}]}}
  end

  test "leaves out muted threads, ignored authors and unreadable categories", ctx do
    muting = lister("muting")
    ignoring = lister("ignoring")
    outsider = lister("outsider")

    {:ok, _} = Subscriptions.set_thread_level(muting, ctx.thread, "muted")
    {:ok, _} = Ignores.set(ignoring, ctx.author, "ignore")
    {:ok, role} = Groups.create_role("staff")
    {:ok, private} = Discussion.create_category(%{title: "Staff", role_ids: [role.id]})
    {:ok, _} = Groups.add_role(ctx.author, role)

    secret = thread_fixture(private, ctx.author, %{title: "Secret"})
    reply(ctx.thread, ctx.author, "Hello")
    flush()

    post = %Discussion.Post{user_id: ctx.author.id}
    assert MailingList.recipients(ctx.thread, post) |> Enum.map(& &1.username) == ["outsider"]
    assert MailingList.recipients(secret, post) == []
    assert outsider.mailing_list_mode
  end

  test "the daily limit caps the emails, and the site setting turns it off", ctx do
    SiteSettings.update(%{"max_mailing_list_emails_per_day" => "1"}, ctx.admin)
    lister("lister")

    reply(ctx.thread, ctx.author, "One")
    assert_email_sent(to: "lister@example.com")
    reply(ctx.thread, ctx.author, "Two")
    refute_receive {:email, %{to: [{"", "lister@example.com"}]}}

    SiteSettings.update(%{"mailing_list_mode" => "false"}, ctx.admin)
    assert MailingList.recipients(ctx.thread, %Discussion.Post{user_id: ctx.author.id}) == []
  end

  test "members in mailing list mode get no watching emails about the post", ctx do
    lister = lister("lister")
    {:ok, _} = Notifications.watch(lister, ctx.thread)

    reply(ctx.thread, ctx.author, "Only once")

    assert_receive {:email, %{subject: "[Firefly] Release plans"}}
    refute_receive {:email, _}
    assert [%{kind: "new_post"}] = Notifications.notifications_for(lister)
  end
end
