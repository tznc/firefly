defmodule Firefly.EmbeddingTest do
  use Firefly.DataCase, async: true

  import Firefly.Fixtures

  alias Firefly.Embedding

  test "feeds: RSS items and Atom entries" do
    atom = """
    <feed xmlns="http://www.w3.org/2005/Atom"><title>Blog</title>
    <entry><title type="html">Tom &amp; Jerry</title>
    <link rel="alternate" href="https://blog.example.com/posts/1"/>
    <summary>Cat &#38; mouse</summary></entry>
    <entry><title>No link</title></entry>
    </feed>
    """

    assert Embedding.entries(atom) == [
             %{
               link: "https://blog.example.com/posts/1",
               title: "Tom & Jerry",
               summary: "Cat & mouse"
             }
           ]

    rss = """
    <rss><channel><item><title><![CDATA[Hello <b>there</b>]]></title>
    <link>https://blog.example.com/posts/2</link></item>
    <item><title>Not the web</title><link>ftp://example.com/x</link></item></channel></rss>
    """

    assert [%{link: "https://blog.example.com/posts/2", title: "Hello there", summary: nil}] =
             Embedding.entries(rss)
  end

  test "hosts: normalized, with optional paths and ports" do
    admin = admin_fixture()

    {:ok, host} =
      Embedding.create_host(
        %{"host" => " HTTPS://Blog.Example.com/ ", "allowed_paths" => ["posts/", ""]},
        admin
      )

    assert host.host == "blog.example.com"
    assert host.allowed_paths == ["/posts/"]
    assert Embedding.host_for("https://blog.example.com/posts/1#c").id == host.id
    assert Embedding.host_for("http://BLOG.example.com:80/posts/1").id == host.id
    refute Embedding.host_for("https://blog.example.com/about")
    refute Embedding.host_for("https://blog.example.com:8443/posts/1")
    refute Embedding.host_for("https://evil.blog.example.com/posts/1")
    refute Embedding.host_for("javascript:alert(1)")

    {:ok, _} = Embedding.create_host(%{"host" => "localhost:4001"}, admin)
    assert Embedding.host_for("http://localhost:4001/anything")
    assert {:error, changeset} = Embedding.create_host(%{"host" => "blog.example.com"}, admin)
    assert "has already been taken" in errors_on(changeset).host

    assert Embedding.normalize_url("https://blog.example.com/posts/1?a=1#comments") ==
             "https://blog.example.com/posts/1?a=1"
  end
end
