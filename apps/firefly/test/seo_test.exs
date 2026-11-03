defmodule Firefly.SEOTest do
  use Firefly.DataCase, async: false

  import Firefly.Fixtures,
    only: [user_fixture: 0, admin_fixture: 0, category_fixture: 1, thread_fixture: 3]

  alias Firefly.{Discussion, Groups, SEO, SiteSettings}

  setup do
    on_exit(&SiteSettings.clear_cache/0)
    %{user: user_fixture(), admin: admin_fixture(), category: category_fixture("Elixir")}
  end

  describe "robots_txt/0" do
    test "disallows the private paths and links the sitemap" do
      robots = SEO.robots_txt()

      assert robots =~ "User-agent: *"
      assert robots =~ "Disallow: /staff/"
      assert robots =~ "Disallow: /messages/"
      assert robots =~ "Sitemap: #{Firefly.Endpoint.url()}/sitemap.xml"
      refute robots =~ "Disallow: /\n"
    end

    test "disallows everything with indexing off", %{admin: admin} do
      {:ok, _} = SiteSettings.update(%{"allow_indexing" => "false"}, admin)

      assert SEO.robots_txt() =~ "Disallow: /\n"
      assert SEO.sitemaps() == []
      assert SEO.sitemap("categories") == :error
    end

    test "includes the admin's extra rules", %{admin: admin} do
      {:ok, _} =
        SiteSettings.update(%{"robots_extra" => "User-agent: GPTBot\nDisallow: /"}, admin)

      assert SEO.robots_txt() =~ "User-agent: GPTBot"
    end
  end

  describe "sitemaps" do
    test "list public topics, categories and tags with their last change", %{
      user: user,
      category: category
    } do
      thread = thread_fixture(category, user, %{title: "Public", body: "Hello", tags: "otp"})
      {:ok, reply} = Discussion.create_post(thread, user, %{body: "A reply"})

      names = Enum.map(SEO.sitemaps(), & &1.name)
      assert "categories" in names
      assert "tags" in names
      assert "topics-1" in names

      {:ok, topics} = SEO.sitemap("topics-1")
      assert [%{loc: loc, lastmod: lastmod}] = topics
      assert loc == Firefly.URLs.thread_url(thread)

      assert DateTime.to_unix(lastmod) ==
               reply.inserted_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

      {:ok, tags} = SEO.sitemap("tags")
      assert [%{loc: tag_loc}] = tags
      assert tag_loc =~ "/tags/otp"

      {:ok, categories} = SEO.sitemap("categories")
      assert Enum.any?(categories, &(&1.loc == Firefly.URLs.category_url(category)))
    end

    test "leave out private, archived, merged and empty content", %{
      user: user,
      admin: admin,
      category: category
    } do
      {:ok, team} = Groups.create_role("team")
      {:ok, private} = Discussion.create_category(%{title: "Secret", role_ids: [team.id]})
      thread_fixture(private, admin, %{title: "Hidden", body: "Secret"})

      archived = thread_fixture(category, user, %{title: "Old", body: "Hello"})
      {:ok, _} = Discussion.archive_thread(archived, true, admin)

      listed = thread_fixture(category, user, %{title: "Listed", body: "Hello"})

      {:ok, topics} = SEO.sitemap("topics-1")
      assert Enum.map(topics, & &1.loc) == [Firefly.URLs.thread_url(listed)]

      {:ok, categories} = SEO.sitemap("categories")
      refute Enum.any?(categories, &(&1.loc == Firefly.URLs.category_url(private)))
    end

    test "an unknown name is an error" do
      assert SEO.sitemap("nope") == :error
      assert SEO.sitemap("topics-zero") == :error
      assert SEO.sitemap("topics-0") == :error
    end
  end

  describe "excerpt/2" do
    test "strips markup and cuts at a word" do
      assert SEO.excerpt("Hello **there**, [link](https://example.com)") ==
               "Hello there, link"

      assert SEO.excerpt("```\ncode\n```\nAfter") == "After"
      assert SEO.excerpt("![img](https://example.com/a.png) Caption") == "Caption"
      assert SEO.excerpt(nil) == nil
      assert SEO.excerpt("   ") == nil

      long = String.duplicate("word ", 60)
      excerpt = SEO.excerpt(long)
      assert String.length(excerpt) <= 160
      assert String.ends_with?(excerpt, "…")
    end
  end
end
