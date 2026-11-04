defmodule FireflyWeb.Api.V1.ThreadJSON do
  @moduledoc """
  JSON representation of threads: `data/1` for the fields every thread
  has, and `listed/1`, which adds what a thread loaded for a list carries
  (tags, the author, counts and read state).
  """
  alias Firefly.Discussion.Thread
  alias Firefly.Moderation.WatchedWords
  alias Firefly.URLs

  def data(%Thread{} = thread) do
    %{
      id: thread.id,
      title: WatchedWords.censor(thread.title),
      slug: thread.slug,
      category_id: thread.category_id,
      pinned: thread.pinned_at != nil,
      closed: thread.closed_at != nil,
      archived: thread.archived_at != nil,
      views: thread.views,
      accepted_post_id: thread.accepted_post_id,
      merged_into_id: thread.merged_into_id,
      url: URLs.thread_url(thread),
      inserted_at: thread.inserted_at,
      updated_at: thread.updated_at
    }
  end

  @doc """
  `data/1` plus what a thread loaded for a list carries: its tags and
  author, how many posts it has and the reader's unread count (null on a
  thread loaded without them).
  """
  def listed(%Thread{} = thread) do
    thread
    |> data()
    |> Map.merge(%{
      tags: tags(thread.tags),
      user: author(thread.first_post),
      posts_count: thread.posts_count,
      last_post_at: thread.last_post_at,
      unread_count: thread.unread_count,
      new: thread.new?
    })
  end

  defp tags(tags) when is_list(tags), do: Enum.map(tags, & &1.name)
  defp tags(_not_loaded), do: nil

  defp author(%{user: %Firefly.Accounts.User{} = user}), do: FireflyWeb.Api.V1.UserJSON.data(user)
  defp author(_none), do: nil
end
