defmodule FireflyImport.NodeBBTest do
  use Firefly.DataCase, async: false

  import Ecto.Query

  alias Firefly.{Import, Repo}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Category, PostLike, Thread}
  alias Firefly.Groups.{Role, RoleMembership}
  alias Firefly.Uploads.Upload
  alias FireflyImport.NodeBBFixture

  @uploads Path.expand("../fixtures/nodebb/uploads", __DIR__)

  @tag :import_redis
  test "imports a NodeBB forum from Redis" do
    url = System.get_env("FIREFLY_IMPORT_REDIS_URL", "redis://localhost:6379/3")
    NodeBBFixture.load_redis(url)

    assert {:ok, _run} =
             FireflyImport.run("nodebb", redis_url: url, uploads_dir: @uploads, skip_after: true)

    assert_imported()
  end

  @tag :import_mongo
  test "imports a NodeBB forum from MongoDB" do
    url =
      System.get_env("FIREFLY_IMPORT_MONGO_URL", "mongodb://localhost:27017") <>
        "/firefly_import_nodebb"

    NodeBBFixture.load_mongo(url)

    assert {:ok, _run} =
             FireflyImport.run("nodebb", mongo_url: url, uploads_dir: @uploads, skip_after: true)

    assert_imported()
  end

  test "needs a database" do
    assert {:error, run} = FireflyImport.run("nodebb", [])
    assert run.error == "--mongo-url or --redis-url is required"
  end

  defp assert_imported do
    admin = Repo.get_by!(User, username: "admin")
    assert admin.email == "admin@example.com"
    assert admin.confirmed_at
    assert admin.bio == "I run this."
    assert admin.avatar_upload_id
    assert admin.inserted_at == ~N[2020-09-13 12:26:40.000000]
    jane = Repo.get_by!(User, username: "Jane_Doe")
    assert jane.name == "Jane Doe"
    troll = Repo.get_by!(User, username: "troll")
    assert troll.suspended_until

    helpers = Repo.get_by!(Role, name: "Helpers")
    assert helpers.description == "They help"
    assert Repo.get_by!(RoleMembership, role_id: helpers.id, user_id: jane.id)
    assert Import.mapped("nodebb", "group", ["administrators"]) == %{}

    general = Repo.get_by!(Category, title: "General & more")
    assert general.color == "#336699"
    help = Repo.get_by!(Category, title: "Help")
    assert help.parent_id == general.id

    welcome = Repo.get_by!(Thread, title: "Welcome & hello") |> Repo.preload([:posts, :tags])
    assert welcome.category_id == help.id
    assert welcome.pinned_at
    assert welcome.closed_at
    assert welcome.views == 9
    assert Enum.map(welcome.tags, & &1.name) == ["intro", "news"]
    refute Repo.get_by(Thread, title: "Deleted")

    [first, reply, guest] = welcome.posts
    logo = Repo.get_by!(Upload, post_id: first.id)
    assert first.body == "**Hi** all ![logo](/uploads/#{logo.token}/1600000000-logo.png)"
    assert first.user_id == admin.id
    assert first.edited_at
    assert reply.user_id == jane.id
    assert guest.deleted_at
    assert Repo.get!(User, guest.user_id).username == "ghost"

    likes =
      Repo.all(
        from(l in PostLike, select: {l.post_id, l.user_id}, order_by: [l.post_id, l.user_id])
      )

    assert likes == [{first.id, jane.id}, {first.id, troll.id}, {reply.id, troll.id}]

    assert Import.find_permalink("/topic/1/welcome-hello/2").thread_id == welcome.id
    assert Import.find_permalink("/post/2").post_id == reply.id
    assert Import.find_permalink("/category/2/help").category_id == help.id
    assert Import.find_permalink("/user/jane-doe").user_id == jane.id
  end
end
