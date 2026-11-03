defmodule FireflyImport.VBulletinTest do
  use Firefly.DataCase, async: false

  import Ecto.Query

  alias Firefly.{Import, Repo}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Category, Thread}
  alias Firefly.Groups.{Role, RoleMembership}
  alias Firefly.Messaging.Conversation
  alias Firefly.Uploads.Upload
  alias FireflyImport.SourceDatabases
  alias FireflyImport.Sources.VBulletin

  @moduletag :import_mysql
  @fixtures Path.expand("../fixtures/vbulletin", __DIR__)
  @logo Path.expand("../fixtures/vbulletin/attachments/2/31.attach", __DIR__)

  test "imports a vBulletin 4 forum, attachments from the file system" do
    url = SourceDatabases.mysql("firefly_import_vb4", Path.join(@fixtures, "vbulletin4.sql"))

    assert {:ok, run} =
             FireflyImport.run("vbulletin",
               source_url: url,
               attachments_dir: Path.join(@fixtures, "attachments"),
               skip_after: true
             )

    assert run.counts["uploads"] == %{"imported" => 2}
    bob = Repo.get_by!(User, username: "Bob_Sons")
    assert bob.name == "Bob & Sons"
    admin = Repo.get_by!(User, username: "Admin")
    assert admin.website == "https://admin.example.com"

    testers = Repo.get_by!(Role, name: "Testers")
    assert Repo.get_by!(RoleMembership, role_id: testers.id, user_id: bob.id)
    refute Repo.get_by(Role, name: "Registered Users")

    main = Repo.get_by!(Category, title: "Main Category")
    general = Repo.get_by!(Category, title: "General & Chat")
    assert general.parent_id == main.id
    assert general.description == "**Talk** here"
    assert Repo.get_by!(Category, title: "Off topic").parent_id == main.id

    hello = Repo.get_by!(Thread, title: ~s{Hello "world"}) |> Repo.preload(:posts)
    assert hello.pinned_at
    assert hello.views == 12
    refute Repo.get_by(Thread, title: "Moderated")
    [first, reply, guest, deleted] = hello.posts
    logo = Repo.get_by!(Upload, post_id: first.id)

    assert first.body ==
             "<strong>Hello</strong> everyone ![logo.png](/uploads/#{logo.token}/logo.png)"

    assert reply.body =~ "@Admin said:"
    assert reply.body =~ "Hi"
    refute reply.body =~ "FONT"
    assert reply.body =~ "` <b>x</b> `"
    assert Repo.get!(User, guest.user_id).username == "Passer-by"
    assert deleted.deleted_at

    closed = Repo.get_by!(Thread, title: "Closed one") |> Repo.preload(:posts)
    assert closed.closed_at
    [post] = closed.posts
    notes = Repo.get_by!(Upload, post_id: post.id)
    assert post.body == "Closed\n\n[notes.txt](/uploads/#{notes.token}/notes.txt)"

    conversation =
      Repo.get_by!(Conversation, title: "A question") |> Repo.preload([:messages, :participants])

    assert conversation.user_id == bob.id
    assert Enum.map(conversation.messages, & &1.body) == ["Can you help?"]
    assert length(conversation.participants) == 2

    assert Import.find_permalink("/showthread.php", "t=10").thread_id == hello.id
    assert Import.find_permalink("/showthread.php/10-hello-world").thread_id == hello.id
    assert Import.find_permalink("/showpost.php", "p=101").post_id == reply.id
    assert Import.find_permalink("/forumdisplay.php", "f=2").category_id == general.id
    assert Import.find_permalink("/member.php", "u=2").user_id == bob.id
  end

  test "imports a vBulletin 5 forum, attachments from the database" do
    url = SourceDatabases.mysql("firefly_import_vb5", Path.join(@fixtures, "vbulletin5.sql"))
    SourceDatabases.mysql_query!(url, "UPDATE filedata SET filedata = ?", [File.read!(@logo)])

    assert {:ok, _run} = FireflyImport.run("vbulletin", source_url: url, skip_after: true)

    main = Repo.get_by!(Category, title: "Main Category")
    general = Repo.get_by!(Category, title: "General")
    assert general.parent_id == main.id
    refute Repo.get_by(Category, title: "Private Messages")

    topic = Repo.get_by!(Thread, title: "First topic") |> Repo.preload(:posts)
    assert topic.category_id == general.id
    assert topic.pinned_at
    [first, reply, comment, removed] = topic.posts
    logo = Repo.get_by!(Upload, post_id: first.id)
    assert first.body == "<strong>Welcome</strong> ![logo.png](/uploads/#{logo.token}/logo.png)"
    assert reply.body =~ "@Admin said:"
    assert comment.body == "A comment"
    assert removed.deleted_at

    conversation =
      Repo.get_by!(Conversation, title: "Hi Bob") |> Repo.preload([:messages, :participants])

    assert Enum.map(conversation.messages, & &1.body) == ["Hello Bob", "Hi!"]
    assert length(conversation.participants) == 2
    refute Repo.exists?(from(t in Thread, where: t.title == "Hi Bob"))

    assert Import.find_permalink("/showthread.php", "t=10").thread_id == topic.id
  end

  test "makes vBulletin's BBCode standard" do
    assert VBulletin.bbcode("[QUOTE=Ann;n5]x[/QUOTE]") =~ "@Ann said:"
    assert VBulletin.bbcode("[CENTER][FONT=Arial]x[/FONT][/CENTER]") == "x"
  end
end
