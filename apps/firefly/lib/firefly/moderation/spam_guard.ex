defmodule Firefly.Moderation.SpamGuard do
  @moduledoc """
  Limits for new users (trust level 0, see `Firefly.TrustLevels`), the
  usual shape of forum spam: each post may contain at most
  `new_user_max_links` links, `new_user_max_images` images,
  `new_user_max_attachments` uploaded files other than images and
  `new_user_max_mentions` @mentions (see `Firefly.SiteSettings`).
  Basic users (trust level 1) and admins are exempt.

  Every post, whoever writes it, may mention at most
  `Firefly.Discussion.Mentions.max_mentions/0` users, so mentions can't be used to
  ping crowds.
  """
  import Ecto.Changeset

  alias Firefly.{SiteSettings, TrustLevels}
  alias Firefly.Discussion.Mentions
  alias Firefly.Accounts.User

  @link_regex ~r{\bhttps?://|\bwww\.}i
  @image_regex ~r{!\[[^\]]*\]\(|<img\b}i
  # Links to uploads that aren't images (an image is `![...](/uploads/...)`).
  @attachment_regex ~r{(?<!!)\[[^\]]*\]\([^)\s]*/uploads/}

  @doc "Adds body errors when a post breaks a limit that applies to its author."
  def validate_post(%Ecto.Changeset{} = changeset, %User{} = user) do
    if TrustLevels.new_user?(user) do
      max_mentions = min(SiteSettings.get("new_user_max_mentions"), Mentions.max_mentions())

      changeset
      |> Mentions.validate_count(max_mentions)
      |> validate_change(:body, &new_user_limits/2)
    else
      Mentions.validate_count(changeset, Mentions.max_mentions())
    end
  end

  defp new_user_limits(:body, body) do
    [
      {&link_count/1, "new_user_max_links", "links", :new_user_links},
      {&image_count/1, "new_user_max_images", "images", :new_user_images},
      {&attachment_count/1, "new_user_max_attachments", "attachments", :new_user_attachments}
    ]
    |> Enum.filter(fn {count, key, _what, _validation} ->
      count.(body) > SiteSettings.get(key)
    end)
    |> Enum.map(fn {_count, key, what, validation} ->
      {:body,
       {"new users can include at most %{count} #{what} per post",
        count: SiteSettings.get(key), validation: validation}}
    end)
  end

  def link_count(body) when is_binary(body), do: length(Regex.scan(@link_regex, body))
  def link_count(_body), do: 0

  @doc "How many images a post embeds."
  def image_count(body) when is_binary(body), do: length(Regex.scan(@image_regex, body))
  def image_count(_body), do: 0

  @doc "How many uploaded files other than images a post links."
  def attachment_count(body) when is_binary(body),
    do: length(Regex.scan(@attachment_regex, body))

  def attachment_count(_body), do: 0
end
