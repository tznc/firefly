defmodule FirestormWeb.Web.PenaltiesTest do
  use FirestormWeb.Web.ConnCase
  use Bamboo.Test, shared: true

  import Ecto.Query, only: [from: 2]

  alias FirestormWeb.{Forums, Penalties, Posting, Repo}
  alias FirestormWeb.Forums.{Notification, StaffAction, User}

  @password "member-password"

  setup do
    admin = admin_fixture(%{username: "boss"})

    {:ok, member} =
      Forums.register_user(%{
        username: "member",
        email: "member@example.com",
        password: @password
      })

    {:ok, member} = Forums.confirm_user(member)
    category = category_fixture("Elixir")
    thread = thread_fixture(category, admin, %{title: "Rules"})
    %{admin: admin, member: member, thread: thread}
  end

  defp silence(member, admin, params \\ %{}) do
    Penalties.penalize(
      :silence,
      member,
      admin,
      Map.merge(%{"duration" => "1w", "reason" => "Spam"}, params)
    )
  end

  defp suspend(member, admin) do
    Penalties.penalize(:suspend, member, admin, %{"duration" => "forever", "reason" => "Abuse"})
  end

  defp thread_path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  describe "penalize/4" do
    test "needs a reason and a future end, and never applies to admins", ctx do
      %{admin: admin, member: member} = ctx
      assert {:error, :no_reason} = silence(member, admin, %{"reason" => "  "})

      assert {:error, :invalid_date} =
               silence(member, admin, %{"duration" => "date", "until" => "2020-01-01"})

      assert {:error, :invalid_date} =
               silence(member, admin, %{"duration" => "date", "until" => "soon"})

      assert {:error, :admin} = silence(admin_fixture(), admin)

      assert {:ok, member} =
               silence(member, admin, %{"duration" => "date", "until" => "2999-05-01"})

      assert member.silenced_until == ~U[2999-05-01 00:00:00Z]
      assert Penalties.ends_text(member.silenced_until) == "until 1 May 2999, 00:00 UTC"
    end

    test "is logged, notified in-app and by email, and expires by date", ctx do
      %{admin: admin, member: member} = ctx
      {:ok, member} = silence(member, admin, %{"duration" => "1d"})
      assert User.silenced?(member)

      assert [%{action: "user.silence", actor_id: actor_id, details: details}] =
               Repo.all(StaffAction)

      assert actor_id == admin.id
      assert %{"reason" => "Spam", "username" => "member"} = details

      assert [
               %Notification{
                 kind: "silenced",
                 body: "Spam",
                 subject: "You've been silenced until " <> _
               }
             ] =
               Repo.all(from(n in Notification, where: n.user_id == ^member.id))

      assert_delivered_email_matches(%{
        to: [{nil, "member@example.com"}],
        subject: "You've been silenced" <> _
      })

      refute User.silenced?(%{member | silenced_until: DateTime.add(DateTime.utc_now(), -1)})

      {:ok, member} = Penalties.lift(:silence, member, admin)
      refute User.silenced?(member)
      assert "user.unsilence" in Enum.map(Repo.all(StaffAction), & &1.action)
    end
  end

  describe "silenced members" do
    setup %{admin: admin, member: member} do
      {:ok, member} = silence(member, admin)
      %{member: member}
    end

    test "can't post, start threads, message or like, and are told until when", ctx do
      %{conn: conn, member: member, thread: thread} = ctx
      assert {:error, {:silenced, _}} = Posting.check(member, thread)
      assert {:error, {:silenced, _}} = Posting.check(member, :new_conversation)
      assert Posting.message(elem(Posting.check(member), 1)) =~ "You've been silenced until"

      [post] = Repo.preload(thread, :posts).posts

      conn
      |> log_in_as(member)
      |> visit(thread_path(thread))
      |> assert_has("#silenced-notice", text: "Reason: Spam")
      |> click_button("Like post #{post.id}")
      |> assert_has("#flash-error", text: "You've been silenced until")

      refute Forums.liked?(post, member)
    end

    test "can't post through the API", %{conn: conn, member: member, thread: thread} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{member.api_token}")
        |> post("/api/v1/posts", post: %{"body" => "hi"}, thread_id: thread.id)

      assert json_response(conn, 403)["error"] =~ "silenced"
    end
  end

  describe "suspended members" do
    test "can't log in, and are told why and until when", ctx do
      %{conn: conn, admin: admin, member: member} = ctx
      {:ok, _} = suspend(member, admin)

      conn
      |> visit(~p"/auth/identity")
      |> fill_in("Username", with: "member")
      |> fill_in("Password", with: @password)
      |> click_button("Log in")
      |> assert_path(~p"/auth/identity")
      |> assert_has("#flash-error", text: "Your account is suspended permanently. Reason: Abuse")

      conn =
        post(build_conn(), "/api/v1/auth/identity",
          user: %{username: "member", password: @password}
        )

      assert json_response(conn, 403)["error"] =~ "suspended permanently"
    end

    test "lose their sessions, open pages and API token", ctx do
      %{conn: conn, admin: admin, member: member, thread: thread} = ctx
      FirestormWeb.Web.Endpoint.subscribe("users_sockets:#{member.id}")
      {:ok, _} = suspend(member, admin)
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}

      conn
      |> log_in_as(member)
      |> visit(~p"/")
      |> refute_has("nav a", text: "Your profile")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{member.api_token}")
        |> post("/api/v1/posts", post: %{"body" => "hi"}, thread_id: thread.id)

      assert response(conn, 401)
    end
  end

  describe "the profile page" do
    test "admins silence, see the badge and lift it", %{conn: conn, admin: admin, member: member} do
      conn
      |> log_in_as(admin)
      |> visit(~p"/users/#{member}")
      |> select("Penalty", option: "Silence (can read, can't post)")
      |> select("Duration", option: "1 week")
      |> click_button("Apply penalty")
      |> assert_has("#flash-error", text: "Give a reason")
      |> fill_in("Reason (the user sees it)", with: "Off-topic flood")
      |> click_button("Apply penalty")
      |> assert_has("#flash-info", text: "member is silenced until")
      |> assert_has("#silenced-badge", text: "Off-topic flood")
      |> click_button("Lift silence")
      |> refute_has("#silenced-badge")

      assert ["user.silence", "user.unsilence"] =
               Repo.all(from(a in StaffAction, order_by: a.id, select: a.action))
    end

    test "admins suspend until a date", %{conn: conn, admin: admin, member: member} do
      conn
      |> log_in_as(admin)
      |> visit(~p"/users/#{member}")
      |> select("Penalty", option: "Suspend (can't log in)")
      |> select("Duration", option: "Until a date")
      |> fill_in("Until (for a date)", with: "2999-01-31")
      |> fill_in("Reason (the user sees it)", with: "Harassment")
      |> click_button("Apply penalty")
      |> assert_has("#suspended-badge", text: "until 31 Jan 2999")

      assert Repo.get!(User, member.id).suspended_until == ~U[2999-01-31 00:00:00Z]
    end

    test "admins can't be penalized; members see no staff tools", ctx do
      %{conn: conn, admin: admin, member: member} = ctx
      {:ok, _} = silence(member, admin)

      conn
      |> log_in_as(admin)
      |> visit(~p"/users/#{admin_fixture()}")
      |> refute_has("#penalty-form")

      conn
      |> log_in_as(user_fixture())
      |> visit(~p"/users/#{member}")
      |> refute_has("#penalties")
    end
  end
end
