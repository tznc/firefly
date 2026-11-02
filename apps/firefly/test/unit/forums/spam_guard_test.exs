defmodule Firefly.Discussion.SpamGuardTest do
  use Firefly.DataCase, async: true

  alias Firefly.{Accounts, Discussion, Groups, Repo}
  alias Firefly.Accounts.User
  alias Firefly.Moderation.SpamGuard
  alias Firefly.SiteSettings.SiteSetting

  @links "see https://a.example and http://b.example and www.c.example"

  defp user(trust_level) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.create_user(%{
        username: "u#{unique}",
        name: "U",
        email: "u#{unique}@example.com",
        trust_level: trust_level
      })

    user
  end

  defp category, do: elem(Discussion.create_category(%{title: "C"}), 1)

  test "counts links, images and attachments" do
    assert SpamGuard.link_count(@links) == 3
    assert SpamGuard.link_count("no links here") == 0

    body =
      "![a](/uploads/abc/a.png) <img src=x> [doc](/uploads/def/doc.pdf) [site](https://x.example)"

    assert SpamGuard.image_count(body) == 2
    assert SpamGuard.attachment_count(body) == 1
  end

  test "new users (trust level 0) can't post more than two links" do
    user = user(0)

    assert {:error, changeset} =
             Discussion.create_thread(category(), user, %{title: "Spam", body: @links})

    [post_changeset] = changeset.changes.posts
    assert "new users can include at most 2 links per post" in errors_on(post_changeset).body

    assert {:ok, thread} =
             Discussion.create_thread(category(), user, %{
               title: "Fine",
               body: "one https://a.example"
             })

    assert {:error, changeset} = Discussion.create_post(thread, user, %{body: @links})
    assert errors_on(changeset).body == ["new users can include at most 2 links per post"]
  end

  test "new users' images, attachments and mentions are limited" do
    user = user(0)
    {:ok, thread} = Discussion.create_thread(category(), user(1), %{title: "T", body: "b"})

    images = "![a](https://x.example/a.png) ![b](https://x.example/b.png)"
    assert {:error, changeset} = Discussion.create_post(thread, user, %{body: images})
    assert "new users can include at most 1 images per post" in errors_on(changeset).body

    attachment = "[doc](/uploads/aaaaaaaaaaaaaaaaaaaaaa/doc.pdf)"
    assert {:error, changeset} = Discussion.create_post(thread, user, %{body: attachment})
    assert "new users can include at most 0 attachments per post" in errors_on(changeset).body

    [a, b, c] = for _ <- 1..3, do: user(1)
    mentions = "@#{a.username} @#{b.username} @#{c.username}"
    assert {:error, changeset} = Discussion.create_post(thread, user, %{body: mentions})
    assert "can mention at most 2 users" in errors_on(changeset).body

    Repo.insert!(%SiteSetting{key: "new_user_max_mentions", value: "3"})
    assert {:ok, _} = Discussion.create_post(thread, user, %{body: mentions})
  end

  test "basic users and admins aren't limited" do
    basic = user(1)
    {:ok, thread} = Discussion.create_thread(category(), basic, %{title: "1", body: "a"})

    refute Firefly.TrustLevels.new_user?(basic)
    assert {:ok, _} = Discussion.create_post(thread, basic, %{body: @links})

    admin = user(0)
    {:ok, role} = Groups.create_role("admin")
    {:ok, _} = Groups.add_role(admin, role)
    admin = Repo.get!(User, admin.id)

    refute Firefly.TrustLevels.new_user?(admin)
    assert {:ok, _} = Discussion.create_post(thread, admin, %{body: @links})
  end
end
