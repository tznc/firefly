defmodule FirestormWeb.FlagsTest do
  use FirestormWeb.DataCase

  alias FirestormWeb.{Flags, Forums, Penalties, Repo, Search}
  alias FirestormWeb.Forums.{Flag, Post, SiteSetting, StaffAction}

  setup do
    admin = user("admin")
    {:ok, role} = Forums.create_role("admin")
    {:ok, _} = Forums.add_role(admin, role)
    author = user("author")
    {:ok, category} = Forums.create_category(%{title: "Elixir"})

    {:ok, thread} =
      Forums.create_thread(category, author, %{title: "Spammy", body: "buy pills now"})

    [first] = Repo.preload(thread, :posts).posts
    {:ok, reply} = Forums.create_post(thread, author, %{body: "more pills"})

    %{admin: admin, role: role, author: author, thread: thread, first: first, reply: reply}
  end

  defp user(name) do
    {:ok, user} = Forums.create_user(%{username: name, name: name, email: "#{name}@example.com"})
    user
  end

  defp flag(post, name, attrs \\ %{"reason" => "spam"}),
    do: Flags.flag_post(post, user(name), attrs)

  test "a flag needs a reason; something else needs a note", %{reply: reply} do
    flagger = user("flagger")

    assert {:error, changeset} = Flags.flag_post(reply, flagger, %{"reason" => "bogus"})
    assert %{reason: ["is invalid"]} = errors_on(changeset)
    assert {:error, changeset} = Flags.flag_post(reply, flagger, %{"reason" => "other"})
    assert %{note: ["say what's wrong"]} = errors_on(changeset)

    assert {:ok, %Flag{status: "pending", note: "copied from elsewhere"}} =
             Flags.flag_post(reply, flagger, %{
               "reason" => "other",
               "note" => " copied from elsewhere "
             })
  end

  test "one flag per user per post, never on your own posts", %{reply: reply, author: author} do
    flagger = user("flagger")
    assert {:ok, _} = Flags.flag_post(reply, flagger, %{"reason" => "spam"})
    assert {:error, :already_flagged} = Flags.flag_post(reply, flagger, %{"reason" => "spam"})
    assert {:error, :unauthorized} = Flags.flag_post(reply, author, %{"reason" => "spam"})
  end

  test "silenced users can't flag", %{reply: reply, admin: admin} do
    flagger = user("flagger")

    {:ok, flagger} =
      Penalties.penalize(:silence, flagger, admin, %{"duration" => "1w", "reason" => "x"})

    assert {:error, {:silenced, _}} = Flags.flag_post(reply, flagger, %{"reason" => "spam"})
  end

  test "enough flags hide the post and tell its author", %{reply: reply, author: author} do
    {:ok, _} = flag(reply, "one")
    {:ok, _} = flag(reply, "two")
    refute Repo.get!(Post, reply.id).hidden_at

    {:ok, _} = flag(reply, "three")
    assert Repo.get!(Post, reply.id).hidden_at
    assert [%{kind: "post_hidden", post_id: post_id}] = notifications(author, "post_hidden")
    assert post_id == reply.id

    # Hidden: no more flags, and nobody's told twice.
    assert {:error, :unauthorized} = flag(Repo.get!(Post, reply.id), "four")
    assert length(notifications(author, "post_hidden")) == 1
  end

  test "the threshold is a site setting", %{reply: reply} do
    Repo.insert!(%SiteSetting{key: "flags_to_hide", value: "1"})
    {:ok, _} = flag(reply, "one")
    assert Repo.get!(Post, reply.id).hidden_at
  end

  test "a hidden first post takes its thread off the lists; hidden posts leave search",
       %{first: first, thread: thread} do
    for name <- ~w(one two three), do: {:ok, _} = flag(first, name)

    refute thread.id in Enum.map(Forums.latest_threads(nil), & &1.id)
    refute thread.id in Enum.map(Forums.top_threads("all", nil), & &1.id)

    assert Search.run(Search.parse("pills"), nil).entries |> Enum.map(& &1.post.body) == [
             "more pills"
           ]
  end

  test "admins get one notification per post, updated with each flag", %{
    reply: reply,
    admin: admin
  } do
    {:ok, _} = flag(reply, "one")
    {:ok, _} = flag(reply, "two", %{"reason" => "other", "note" => "rude"})

    assert [notification] = notifications(admin, "flagged")
    assert notification.subject == ~s(2 flags on @author's post in "Spammy")
    assert notification.body =~ "@two: Something else (rude)"
    assert notification.body =~ "@one: Spam"

    {:ok, _} = Forums.mark_notification_read(notification)
    {:ok, _} = flag(reply, "three")
    assert length(notifications(admin, "flagged")) == 2
  end

  test "pending counts and who flagged what", %{reply: reply, first: first} do
    {:ok, _} = flag(reply, "one")
    flagger = user("flagger")
    {:ok, _} = Flags.flag_post(first, flagger, %{"reason" => "off_topic"})

    assert Flags.pending_counts([first, reply]) == %{first.id => 1, reply.id => 1}
    assert Flags.flagged_ids([first, reply], flagger) == MapSet.new([first.id])
  end

  test "unconfirmed accounts can't flag", %{reply: reply} do
    {:ok, fresh} =
      Forums.register_user(%{
        username: "fresh",
        email: "fresh@example.com",
        password: "correct horse battery"
      })

    assert {:error, :unconfirmed} = Flags.flag_post(reply, fresh, %{"reason" => "spam"})
    assert Flags.message(:unconfirmed) =~ "confirm your email"
  end

  test "flags never hide an admin's post, but admins still hear of them", ctx do
    {:ok, thread} =
      Forums.create_thread(Repo.get!(Forums.Category, ctx.thread.category_id), ctx.admin, %{
        title: "Announcement",
        body: "read me"
      })

    [post] = Repo.preload(thread, :posts).posts
    other_admin = user("other_admin")
    {:ok, _} = Forums.add_role(other_admin, ctx.role)

    for name <- ~w(one two three), do: {:ok, _} = flag(post, name)

    refute Repo.get!(Post, post.id).hidden_at
    assert [%{subject: "3 flags on @admin's post" <> _}] = notifications(other_admin, "flagged")
  end

  test "an admin can unhide a post, dismissing its flags", ctx do
    %{reply: reply, admin: admin} = ctx
    for name <- ~w(one two three), do: {:ok, _} = flag(reply, name)
    assert Repo.get!(Post, reply.id).hidden_at

    assert {:ok, %Post{hidden_at: nil}} = Flags.unhide(reply, admin)
    refute Repo.get!(Post, reply.id).hidden_at
    assert Flags.pending_counts([reply]) == %{}

    assert Repo.all(Flag) |> Enum.map(&{&1.status, &1.reviewed_by_id}) |> Enum.uniq() ==
             [{"disagreed", admin.id}]

    assert [%{action: "post.unhide", details: %{"flags" => 3}}] =
             Repo.all(from(a in StaffAction, where: a.action == "post.unhide"))

    # Twice (say, two admins at once): the second has nothing to do.
    assert {:error, :not_hidden} = Flags.unhide(reply, admin)
  end

  test "a hidden post's content and link previews stay out of the API", %{reply: reply} do
    hidden = %{
      reply
      | hidden_at: DateTime.utc_now(:second),
        oembeds: [{"https://spam.example", %{}}]
    }

    assert %{body: "", body_html: "", oembeds: [], hidden: true} =
             FirestormWeb.Web.Api.V1.PostJSON.data(hidden)
  end

  defp notifications(user, kind),
    do: user |> Forums.notifications_for() |> Enum.filter(&(&1.kind == kind))
end
