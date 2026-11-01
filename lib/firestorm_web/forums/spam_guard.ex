defmodule FirestormWeb.Forums.SpamGuard do
  @moduledoc """
  Limits for new accounts, the usual shape of forum spam: until an account is
  `new_user_hours` old (a day) and has a few posts, each post may contain at
  most `new_user_max_links` links (two); see `FirestormWeb.SiteSettings`.
  Admins are exempt.

  Every post, whoever writes it, may mention at most
  `FirestormWeb.Mentions.max_mentions/0` users, so mentions can't be used to
  ping crowds.
  """
  import Ecto.{Changeset, Query}

  alias FirestormWeb.{Forums, Repo, SiteSettings}
  alias FirestormWeb.Forums.{Post, User}

  @new_user_post_count 3

  @link_regex ~r{\bhttps?://|\bwww\.}i

  @doc "Adds a body error when a new user's post has too many links, or any post too many mentions."
  def validate_post(%Ecto.Changeset{} = changeset, %User{} = user) do
    changeset
    |> FirestormWeb.Mentions.validate_count()
    |> validate_change(:body, fn :body, body ->
      max_links = SiteSettings.get("new_user_max_links")

      if link_count(body) > max_links and new_user?(user) do
        [
          body:
            {"new accounts can include at most %{count} links per post",
             count: max_links, validation: :new_user_links}
        ]
      else
        []
      end
    end)
  end

  def link_count(body) when is_binary(body), do: length(Regex.scan(@link_regex, body))
  def link_count(_body), do: 0

  @doc "Whether the account is still subject to new-user limits."
  def new_user?(%User{} = user) do
    not Forums.admin?(user) and (recent?(user) or few_posts?(user))
  end

  defp recent?(%User{inserted_at: inserted_at}) do
    cutoff =
      NaiveDateTime.add(NaiveDateTime.utc_now(), -SiteSettings.get("new_user_hours"), :hour)

    NaiveDateTime.compare(inserted_at, cutoff) == :gt
  end

  defp few_posts?(%User{id: id}) do
    Post
    |> where([p], p.user_id == ^id)
    |> limit(@new_user_post_count)
    |> select(1)
    |> Repo.all()
    |> length() < @new_user_post_count
  end
end
