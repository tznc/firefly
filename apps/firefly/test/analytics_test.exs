defmodule Firefly.AnalyticsTest do
  # The in-memory buffer is shared by every test.
  use Firefly.DataCase, async: false

  import Firefly.Fixtures

  alias Firefly.{Analytics, Repo, SiteSettings}
  alias Firefly.Analytics.Buffer
  alias Firefly.Discussion.Thread

  setup do
    Buffer.take()
    :ok
  end

  defp count(table, where) do
    Repo.one(
      from(r in table,
        where: ^Enum.to_list(where),
        select: type(sum(r.count), :integer)
      )
    )
  end

  test "crawlers are told apart by user agent" do
    assert Analytics.crawler?("Mozilla/5.0 (compatible; Googlebot/2.1)")
    assert Analytics.crawler?("curl/8.5.0")
    assert Analytics.crawler?(nil)
    assert Analytics.crawler?("")
    refute Analytics.crawler?("Mozilla/5.0 (X11; Linux x86_64) Firefox/140.0")

    assert Analytics.kind(nil, "Googlebot/2.1") == "crawler"
    assert Analytics.kind(%{id: 1}, "Mozilla/5.0 Firefox/140.0") == "logged_in"
    assert Analytics.kind(nil, "Mozilla/5.0 Firefox/140.0") == "anonymous"
  end

  test "page views and referrers are counted in memory and added up when flushed" do
    today = Date.utc_today()

    for _ <- 1..3, do: Analytics.page_view("anonymous")
    Analytics.page_view("api")
    Analytics.referrer("https://www.news.example/item?id=1", "forum.test")
    Analytics.referrer("https://forum.test/categories", "forum.test")
    Analytics.referrer("android-app://com.example", "forum.test")
    assert :ok = Analytics.flush()

    Analytics.page_view("anonymous")
    Analytics.flush()

    assert count("analytics_page_views", kind: "anonymous", date: today) == 4
    assert {today, "api", 1} in Analytics.page_views(today, today)
    assert Analytics.top_referrers(today, today) == [{"news.example", 1}]
    # Nothing is left to write.
    assert Buffer.take() == []
  end

  test "a topic view counts once per viewer and day, and no address is stored" do
    thread = thread_fixture(category_fixture(), user_fixture())
    user = user_fixture()

    Analytics.topic_view(thread.id, {:user, user.id})
    Analytics.topic_view(thread.id, {:user, user.id})
    Analytics.topic_view(thread.id, {:anonymous, {203, 0, 113, 7}, "Firefox"})
    Analytics.topic_view(thread.id, {:anonymous, {203, 0, 113, 7}, "Firefox"})
    Analytics.topic_view(thread.id, {:anonymous, {203, 0, 113, 7}, "Safari"})
    # A thread that's gone isn't counted.
    Analytics.topic_view(-1, {:user, user.id})
    Analytics.flush()

    # Again in a later batch: still the same viewer today.
    Analytics.topic_view(thread.id, {:anonymous, {203, 0, 113, 7}, "Firefox"})
    Analytics.flush()

    assert Repo.get!(Thread, thread.id).views == 3
    today = Date.utc_today()
    assert [{%Thread{id: id}, 3}] = Analytics.top_topics(today, today)
    assert id == thread.id

    viewers = Repo.all(from(v in "analytics_topic_viewers", select: v.viewer))
    assert length(viewers) == 3
    refute Enum.any?(viewers, &String.contains?(&1, "203.0.113.7"))
    assert "u:#{user.id}" in viewers
  end

  test "the day's salt and viewers are dropped once the day is over" do
    thread = thread_fixture(category_fixture(), user_fixture())
    yesterday = Date.add(Date.utc_today(), -1)

    Repo.insert_all("analytics_topic_viewers", [
      %{date: yesterday, thread_id: thread.id, viewer: "a:old"}
    ])

    Repo.insert_all("analytics_salts", [%{date: yesterday, salt: "old"}])
    Repo.delete_all("job_runs")

    Analytics.run_due()

    assert Repo.aggregate("analytics_topic_viewers", :count) == 0
    assert Repo.aggregate(from(s in "analytics_salts", where: s.date == ^yesterday), :count) == 0
  end

  test "link clicks count only for links the post has" do
    thread =
      thread_fixture(category_fixture(), user_fixture(), %{
        body: "See https://elixir-lang.org/ and [docs](https://hexdocs.pm/elixir?a=1&b=2)"
      })

    [post] = Repo.preload(thread, :posts).posts

    Analytics.link_click(post.id, "https://elixir-lang.org/")
    Analytics.link_click(post.id, "https://elixir-lang.org/")
    Analytics.link_click(post.id, "https://hexdocs.pm/elixir?a=1&amp;b=2")
    Analytics.link_click(post.id, "https://evil.example/")
    Analytics.link_click(post.id, "javascript:alert(1)")
    Analytics.flush()

    assert Analytics.link_clicks([post]) == %{
             post.id => %{
               "https://elixir-lang.org/" => 2,
               "https://hexdocs.pm/elixir?a=1&amp;b=2" => 1
             }
           }
  end

  test "the setting turns it off" do
    assert Analytics.enabled?()
    {:ok, _} = SiteSettings.update(%{"analytics" => "false"}, admin_fixture())
    refute Analytics.enabled?()
  end
end
