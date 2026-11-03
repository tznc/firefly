defmodule FireflyWeb.DigestsTest do
  use FireflyWeb.ConnCase
  use Bamboo.Test, shared: true

  alias Firefly.{Discussion, Groups, JobRuns, Notifications, Repo}
  alias Firefly.Accounts.Ignores
  alias Firefly.Notifications.Digests
  alias Firefly.Accounts.User
  alias Firefly.Notifications.Subscriptions
  alias Firefly.SiteSettings.SiteSetting

  setup do
    admin = admin_fixture()
    general = category_fixture("General")
    reader = away(user_fixture())
    %{admin: admin, general: general, reader: reader}
  end

  # A member who joined long ago and was last here ten days ago.
  defp away(user, attrs \\ []) do
    user
    |> Ecto.Changeset.change(
      Keyword.merge(
        [
          inserted_at: ~N[2025-01-01 00:00:00.000000],
          last_seen_at: DateTime.add(DateTime.utc_now(:second), -10, :day)
        ],
        attrs
      )
    )
    |> Repo.update!()
  end

  defp reload(user), do: Repo.get!(User, user.id)

  defp digest_to(user) do
    receive do
      {:delivered_email, %{to: [{_, address}]} = email} when address == user.email -> email
    after
      0 -> nil
    end
  end

  test "an away member gets a digest of popular new threads, once", ctx do
    thread = thread_fixture(ctx.general, ctx.admin, %{title: "Big news"})
    liker = user_fixture()
    {:ok, reply} = Discussion.create_post(thread, liker, %{body: "Great reply"})
    Discussion.like_post(reply, ctx.admin)

    assert Digests.send_due() == 1
    email = digest_to(ctx.reader)
    assert email.subject =~ "Summary since"
    assert email.html_body =~ "Big news"
    assert email.html_body =~ "Popular replies"
    assert email.text_body =~ "Big news"
    assert email.headers["List-Unsubscribe-Post"] == "List-Unsubscribe=One-Click"
    assert email.headers["List-Unsubscribe"] =~ "/email/unsubscribe/"
    assert reload(ctx.reader).last_digest_at

    # Not again within the week, even from another node.
    assert Digests.send_due() == 0
  end

  test "nothing goes to members who are around, chose never, or aren't eligible", ctx do
    thread_fixture(ctx.general, ctx.admin)
    Repo.update!(Ecto.Changeset.change(ctx.reader, last_seen_at: DateTime.utc_now(:second)))
    away(user_fixture(), digest_frequency: "never")
    away(user_fixture(), confirmed_at: nil)
    away(user_fixture(), suspended_until: ~U[2099-01-01 00:00:00Z])

    assert Digests.send_due() == 0
  end

  test "follows the frequency: daily members get one after a day", ctx do
    daily =
      away(user_fixture(),
        digest_frequency: "daily",
        last_seen_at: DateTime.add(DateTime.utc_now(), -2, :day) |> DateTime.truncate(:second)
      )

    thread_fixture(ctx.general, ctx.admin)

    Repo.update!(
      Ecto.Changeset.change(ctx.reader,
        last_seen_at: DateTime.add(DateTime.utc_now(:second), -2, :day)
      )
    )

    assert Digests.send_due() == 1
    assert digest_to(daily)
  end

  test "nothing new, nothing sent (but the period still counts)", ctx do
    assert Digests.send_due() == 0
    assert reload(ctx.reader).last_digest_at
  end

  test "leaves out private categories, muted threads and ignored people", ctx do
    {:ok, role} = Groups.create_role("insiders")
    {:ok, secret} = Discussion.create_category(%{title: "Secret"})
    Repo.insert_all("forums_category_roles", [%{category_id: secret.id, role_id: role.id}])
    thread_fixture(secret, ctx.admin, %{title: "Hidden plans"})

    muted = thread_fixture(ctx.general, ctx.admin, %{title: "Muted thing"})
    {:ok, _} = Subscriptions.set_thread_level(ctx.reader, muted, "muted")

    troll = user_fixture()
    {:ok, _} = Ignores.set(ctx.reader, troll, "ignore")
    thread_fixture(ctx.general, troll, %{title: "Troll bait"})
    thread_fixture(ctx.general, ctx.admin, %{title: "Fine thread"})

    %{threads: threads} = Digests.build(reload(ctx.reader))
    assert Enum.map(threads, & &1.title) == ["Fine thread"]
  end

  test "unread notifications alone make a digest", ctx do
    {:ok, _} =
      Notifications.notify(ctx.reader, %{
        kind: "promoted",
        subject: "You're now a member",
        body: "b",
        url: "/"
      })

    assert %{threads: [], notifications: {1, [%{subject: "You're now a member"}]}} =
             Digests.build(reload(ctx.reader))
  end

  test "the site setting turns digests off" do
    Repo.insert!(%SiteSetting{key: "digests_enabled", value: "false"})
    assert Digests.run_due() == :ok
    assert JobRuns.claim("digests", 900)
  end

  test "unsubscribing: one click, the page, and settings", %{conn: conn, reader: reader} do
    url = Digests.unsubscribe_url(reader)
    path = URI.parse(url).path

    conn
    |> visit(path)
    |> click_button("Unsubscribe")
    |> assert_has("#unsubscribed")

    assert reload(reader).digest_frequency == "never"

    Repo.update!(Ecto.Changeset.change(reader, digest_frequency: nil))
    response = build_conn() |> post(path) |> response(200)
    assert response =~ "Unsubscribed"
    assert reload(reader).digest_frequency == "never"

    assert build_conn() |> post("/email/unsubscribe/forged") |> response(404)

    conn
    |> log_in_as(reader)
    |> visit(~p"/settings/notifications")
    |> select("When I haven't visited in a while, email me a summary", option: "Monthly")
    |> click_button("Save")

    assert reload(reader).digest_frequency == "monthly"
  end
end
