defmodule Firefly.Profiles do
  @moduledoc """
  What others may see of a member: their profile page (with its summary
  and activity stream) and user card.

  Two privacy preferences apply. "Hide my public profile and presence"
  (`hide_profile`) leaves only the username and avatar for others: no bio,
  stats, activity, last seen, and no listing in the user directory.
  "Hide my activity" (`hide_profile_activity`) keeps the profile but hides
  the activity stream and the summary's top posts. Either way the member
  themselves and admins see everything.
  """

  alias Firefly.{Directory, Forums}
  alias Firefly.Forums.User

  @activity_filters [
    {"all", "All"},
    {"topics", "Topics"},
    {"replies", "Replies"},
    {"likes", "Likes given"},
    {"solved", "Solved"}
  ]

  @doc "The activity stream's tabs: `{filter, label}` (see `Forums.user_posts/3`)."
  def activity_filters, do: @activity_filters

  @doc "Whether `viewer` sees `user`'s profile, stats and presence (last seen)."
  def visible?(%User{hide_profile: false}, _viewer), do: true
  def visible?(user, viewer), do: own_or_staff?(user, viewer)

  @doc "Whether `viewer` sees `user`'s activity (posts, likes, top posts)."
  def activity_visible?(%User{hide_profile: false, hide_profile_activity: false}, _viewer),
    do: true

  def activity_visible?(user, viewer), do: own_or_staff?(user, viewer)

  defp own_or_staff?(_user, nil), do: false
  defp own_or_staff?(%User{id: id}, %User{id: id}), do: true
  defp own_or_staff?(_user, viewer), do: Forums.admin?(viewer)

  @doc "`user`'s all-time stats (see `Firefly.Directory`)."
  defdelegate stats(user), to: Directory, as: :user_stats

  @doc """
  The profile summary for `viewer`: stats, and `user`'s most liked threads
  and replies (empty when their activity is hidden).
  """
  def summary(%User{} = user, viewer) do
    {topics, replies} =
      if activity_visible?(user, viewer),
        do:
          {Forums.top_user_posts(user, viewer, :topics),
           Forums.top_user_posts(user, viewer, :replies)},
        else: {[], []}

    %{stats: stats(user), top_topics: topics, top_replies: replies}
  end

  @doc "The start of `user`'s bio, as plain text, for the user card."
  def bio_excerpt(%User{bio: nil}), do: nil

  def bio_excerpt(%User{bio: bio}) do
    text = bio |> String.replace(~r/[#*_`>\[\]]/, "") |> String.replace(~r/\s+/, " ")
    text = String.trim(text)
    if String.length(text) > 160, do: String.slice(text, 0, 157) <> "...", else: text
  end
end
