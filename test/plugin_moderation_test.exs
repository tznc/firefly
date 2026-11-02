defmodule FirestormWeb.PluginModerationTest do
  use FirestormWeb.Web.ConnCase

  @moduletag :capture_log

  import Ecto.Query
  import FirestormWeb.DataCase, only: [errors_on: 1]
  import FirestormWeb.PluginHelpers

  alias FirestormWeb.{Flags, Forums, Plugins, Repo, ReplyAddress, Review}
  alias FirestormWeb.Forums.{Post, StaffAction}

  # Rejects posts saying "casino", queues those saying "crypto", allows the rest.
  @moderator """
  exports.moderate_post = ({kind, title, body}) => {
    const text = (title || "") + " " + body;
    if (/casino/i.test(text)) return {action: "reject", message: "No gambling ads, please."};
    if (/crypto/i.test(text)) return {action: "queue", reason: "mentions crypto (" + kind + ")"};
    return {action: "allow"};
  };
  """

  setup do
    admin = admin_fixture()
    member = user_fixture()
    category = category_fixture("Public")
    thread = thread_fixture(category, member, %{title: "Hello", body: "first"})
    %{admin: admin, member: member, category: category, thread: thread}
  end

  defp moderator(admin, js \\ @moderator, id \\ "guard") do
    install_plugin!(
      admin,
      %{"id" => id, "name" => "Guard", "hooks" => ["moderate_post"], "permissions" => ["read"]},
      %{"index.js" => js},
      enable: true
    )
  end

  describe "moderate_post" do
    test "rejects with the plugin's message, on replies, threads and edits",
         %{admin: admin, member: member, thread: thread, category: category} do
      moderator(admin)

      assert {:error, changeset} =
               Forums.create_post(thread, member, %{body: "Best casino in town"})

      assert %{body: ["No gambling ads, please."]} = errors_on(changeset)

      assert {:error, changeset} =
               Forums.create_thread(category, member, %{title: "Casino night", body: "come"})

      assert %{posts: [%{body: ["No gambling ads, please."]}]} = errors_on(changeset)

      {:ok, post} = Forums.create_post(thread, member, %{body: "Fine words"})
      assert {:error, changeset} = Forums.update_post(post, member, %{body: "casino!"})
      assert %{body: ["No gambling ads, please."]} = errors_on(changeset)
    end

    test "queues for review, naming the plugin", %{
      admin: admin,
      member: member,
      thread: thread,
      conn: conn
    } do
      moderator(admin)

      assert {:ok, post} = Forums.create_post(thread, member, %{body: "Buy crypto"})

      assert %Post{queued_at: %DateTime{}, queued_reason: "Plugin Guard: mentions crypto (post)"} =
               post

      conn
      |> log_in_as(admin)
      |> visit(~p"/staff/review")
      |> assert_has("#queued-#{post.id}", text: "Plugin Guard: mentions crypto (post)")

      {:ok, approved} = Review.approve(post, admin)
      assert %Post{queued_at: nil, queued_reason: nil} = Repo.get!(Post, approved.id)
    end

    test "applies to the API and inbound email too", %{
      admin: admin,
      member: member,
      thread: thread,
      conn: conn
    } do
      moderator(admin)

      response =
        conn
        |> put_req_header("authorization", "Bearer #{member.api_token}")
        |> post(~p"/api/v1/posts", post: %{"body" => "casino time"}, thread_id: thread.id)
        |> json_response(422)

      assert inspect(response) =~ "No gambling ads, please."

      member = Repo.update!(Ecto.Changeset.change(member, email: "member@example.com"))

      build_conn()
      |> post("/inbound/sendgrid?token=test-inbound-token", %{
        "to" => ReplyAddress.address(thread, member),
        "from" => "member@example.com",
        "text" => "casino by email",
        "subject" => "Re"
      })
      |> response(200)

      refute Repo.get_by(Post, body: "casino by email")
    end

    test "the web form shows the rejection", %{
      admin: admin,
      member: member,
      thread: thread,
      conn: conn
    } do
      moderator(admin)

      conn
      |> log_in_as(member)
      |> visit(~p"/categories/#{thread.category_id}/threads/#{thread}/posts/new")
      |> fill_in("Body", with: "casino casino")
      |> click_button("Reply")
      |> assert_has("form", text: "No gambling ads, please.")
    end

    test "a failing plugin fails open by default, closed when staff say so",
         %{admin: admin, member: member, thread: thread} do
      moderator(admin, "exports.moderate_post = () => { for (;;) {} }")

      assert {:ok, %Post{queued_at: nil}} = Forums.create_post(thread, member, %{body: "one"})

      :ok = Plugins.set_fail_closed("guard", true, admin)
      assert {:error, changeset} = Forums.create_post(thread, member, %{body: "two"})
      assert %{body: ["Your post couldn't be checked right now." <> _]} = errors_on(changeset)

      assert [%StaffAction{details: %{"fail_closed" => %{"before" => false, "after" => true}}}] =
               Repo.all(from(a in StaffAction, where: a.action == "plugin.settings"))
    end

    test "admins and private categories aren't checked", %{admin: admin} do
      moderator(admin)
      {:ok, role} = Forums.create_role("staff")
      {:ok, private} = Forums.create_category(%{title: "Staff", role_ids: [role.id]})
      insider = user_fixture()
      {:ok, _} = Forums.add_role(insider, role)

      assert {:ok, _} =
               Forums.create_thread(private, insider, %{title: "Casino plans", body: "shh"})

      assert {:ok, _} =
               Forums.create_thread(category_fixture("Open"), admin, %{
                 title: "Casino",
                 body: "ok"
               })
    end

    test "the first rejection wins over queueing; core plugins moderate too",
         %{admin: admin, member: member, thread: thread} do
      defmodule Strict do
        use FirestormWeb.Plugin,
          id: "strict",
          name: "Strict",
          version: "1.0.0",
          firefly: "~> 1.0",
          permissions: ["read"]

        @impl true
        def moderate_post(_plugin, %{"body" => body}) do
          if body =~ "shout",
            do: {:ok, %{"action" => "reject", "message" => "No shouting."}},
            else: {:ok, %{"action" => "allow"}}
        end
      end

      moderator(admin)

      with_core_plugins([Strict], fn ->
        assert {:error, changeset} = Forums.create_post(thread, member, %{body: "crypto shout"})
        assert %{body: ["No shouting."]} = errors_on(changeset)

        assert {:ok, %Post{queued_at: %DateTime{}}} =
                 Forums.create_post(thread, member, %{body: "crypto"})
      end)
    end
  end

  describe "flag_created" do
    test "can hide a flagged post at once", %{admin: admin, member: member, thread: thread} do
      install_plugin!(
        admin,
        %{
          "id" => "triage",
          "name" => "Triage",
          "hooks" => ["flag_created"],
          "permissions" => ["flag"]
        },
        %{
          "index.js" =>
            "exports.flag_created = ({flag}) => ({action: flag.reason === 'spam' ? 'hide' : 'none'})"
        },
        enable: true
      )

      {:ok, spam} = Forums.create_post(thread, member, %{body: "spam"})
      {:ok, rude} = Forums.create_post(thread, member, %{body: "rude"})
      flagger = user_fixture()

      {:ok, _} = Flags.flag_post(rude, flagger, %{reason: "inappropriate"})
      refute Post.hidden?(Repo.get!(Post, rude.id))

      {:ok, _} = Flags.flag_post(spam, flagger, %{reason: "spam"})
      assert Post.hidden?(Repo.get!(Post, spam.id))
    end

    test "needs the flag permission" do
      assert {:error, message} =
               FirestormWeb.Plugin.Manifest.parse(
                 %{
                   "id" => "tri",
                   "name" => "T",
                   "version" => "1.0.0",
                   "firefly" => "~> 1.0",
                   "hooks" => ["flag_created"]
                 },
                 "upload"
               )

      assert message =~ "the flag_created hook needs the flag permission"
    end
  end
end
