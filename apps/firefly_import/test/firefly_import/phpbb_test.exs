defmodule FireflyImport.PhpBBTest do
  use Firefly.DataCase, async: false

  import Ecto.Query

  alias Firefly.{Import, Repo}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Category, Poll, Thread}
  alias Firefly.Groups.{Role, RoleMembership}
  alias Firefly.Messaging.Conversation
  alias Firefly.Uploads.Upload
  alias FireflyImport.SourceDatabases
  alias FireflyImport.Sources.PhpBB

  @moduletag :import_mysql
  @fixtures Path.expand("../fixtures/phpbb", __DIR__)

  setup_all do
    {:ok, url: SourceDatabases.mysql("firefly_import_phpbb", Path.join(@fixtures, "phpbb.sql"))}
  end

  defp import!(url) do
    FireflyImport.run("phpbb",
      source_url: url,
      files_dir: Path.join(@fixtures, "files"),
      permalink_prefix: "forum/",
      skip_after: true
    )
  end

  test "imports a phpBB forum", %{url: url} do
    assert {:ok, run} = import!(url)
    assert run.counts["users"] == %{"imported" => 2}

    admin = Repo.get_by!(User, username: "Admin_Co")
    assert admin.name == "Admin & Co"
    assert admin.email == "admin@example.com"
    assert admin.password_hash == nil
    assert admin.inserted_at == ~N[2010-01-01 00:00:00.000000]
    bob = Repo.get_by!(User, username: "Bob")
    refute Repo.get_by(User, username: "Googlebot")

    mods = Repo.get_by!(Role, name: "Moderators")
    assert mods.description == "<strong>The</strong> mods"
    assert Repo.get_by!(RoleMembership, role_id: mods.id, user_id: admin.id).owner
    refute Repo.get_by(RoleMembership, role_id: mods.id, user_id: bob.id)
    refute Repo.get_by(Role, name: "GUESTS")

    main = Repo.get_by!(Category, title: "Main")
    news = Repo.get_by!(Category, title: "Announcements")
    assert news.parent_id == main.id
    assert news.description == "News & updates"
    assert Repo.get_by!(Category, title: "Archive").parent_id == main.id
    refute Repo.get_by(Category, title: "Our website")

    welcome = Repo.get_by!(Thread, title: ~s{Welcome "home"}) |> Repo.preload(:posts)
    assert welcome.pinned_at
    assert welcome.views == 99
    refute Repo.get_by(Thread, title: "Moved here")
    refute Repo.get_by(Thread, title: "Awaiting approval")

    [first, guest, rude] = welcome.posts

    [logo, other] =
      Repo.all(from(u in Upload, where: u.post_id == ^first.id, order_by: u.filename))

    assert first.body =~ "<strong>Hello</strong> & welcome!"
    assert first.body =~ "@Bob said:"
    assert first.body =~ "[this](<https://example.com>) :)"
    assert first.body =~ "![logo.png](/uploads/#{logo.token}/logo.png)"
    assert String.ends_with?(first.body, "![other.png](/uploads/#{other.token}/other.png)")
    assert first.edited_at
    assert Repo.get!(User, guest.user_id).username == "Visitor"
    assert rude.deleted_at

    locked = Repo.get_by!(Thread, title: "Old and locked") |> Repo.preload(:posts)
    assert locked.closed_at
    [old] = locked.posts
    assert old.body =~ "<em>Old</em> post :D at http://old.example.com/"
    assert old.body =~ "- one\n- two"

    poll = Repo.get_by!(Poll, post_id: first.id) |> Repo.preload([:options, :votes])
    assert poll.kind == "multiple"
    assert poll.max_choices == 2
    assert Enum.map(poll.options, & &1.text) == ["Yes", "No", "Maybe"]
    assert length(poll.votes) == 3

    assert Repo.one(from(b in "forums_bookmarks", select: {b.user_id, b.post_id})) ==
             {admin.id, old.id}

    conversation =
      Repo.get_by!(Conversation, title: "Question") |> Repo.preload([:messages, :participants])

    assert conversation.user_id == bob.id
    assert Enum.map(conversation.messages, & &1.body) |> hd() =~ "Can you help?"
    assert Enum.at(conversation.messages, 1).body == "Sure."
    assert length(conversation.participants) == 2

    assert Import.find_permalink("/forum/viewtopic.php", "f=2&t=10").thread_id == welcome.id
    assert Import.find_permalink("/forum/viewtopic.php", "p=110").post_id == old.id
    assert Import.find_permalink("/forum/viewforum.php", "f=2").category_id == news.id

    assert Import.find_permalink("/forum/memberlist.php", "mode=viewprofile&u=3").user_id ==
             bob.id

    assert {:ok, again} = import!(url)
    assert again.counts["posts"] == %{"skipped" => 4}
  end

  test "reads both of phpBB's stored formats" do
    assert PhpBB.to_bbcode("<r><B><s>[b]</s>x<e>[/b]</e></B> &lt;3<br/>y</r>", "") ==
             "[b]x[/b] <3\ny"

    assert PhpBB.to_bbcode("[b:u1]x[/b:u1] [list:u1][*:u1]a[/*:m:u1][/list:o:u1] &amp;", "u1") ==
             "[b]x[/b] [list][*]a[/list] &"
  end
end
