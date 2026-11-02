defmodule FireflyWeb.Api.V1.SearchJSON do
  @moduledoc "JSON representation of search results."
  alias Firefly.URLs

  def index(%{page: page}) do
    %{
      results: Enum.map(page.entries, &result/1),
      page: page.page_number,
      total_pages: page.total_pages,
      total_entries: page.total_entries
    }
  end

  defp result(%{post: post, thread: thread, headline: headline}) do
    %{
      post_id: post.id,
      thread_id: thread.id,
      thread_title: thread.title,
      category_id: thread.category_id,
      username: post.user.username,
      url: "#{URLs.thread_url(thread)}#post-#{post.id}",
      headline_html: headline,
      inserted_at: post.inserted_at
    }
  end
end
