defmodule Firefly.Notifications.MailingList do
  @moduledoc """
  Mailing list mode, as in Discourse: members who turn it on (in their
  notification settings, while the `mailing_list_mode` site setting allows
  it) get every new thread and reply by email, and can answer by email
  through the usual signed reply address (see
  `Firefly.Notifications.ReplyAddress`).

  Not what they can't read (restricted categories, posts awaiting
  approval), what's in threads, categories or tags they muted, or what
  members they mute or ignore wrote; nor their own posts, unless they turn
  "no echo" off (`mailing_list_no_echo`). Each member gets at most
  `max_mailing_list_emails_per_day` such emails a day (UTC); posts over it
  wait on the site. Only confirmed addresses get them.

  A member the post is mailed to (or would be, but for the daily limit)
  gets no other email about it, so nothing arrives twice: their in-app
  notifications stay. The fan-out (`Firefly.Notifications.FanOut`) queues
  them after the post is saved, one job each (`EmailWorker`).
  """

  import Ecto.Query

  alias Firefly.{Repo, SiteSettings}
  alias Firefly.Accounts.{Ignores, User}
  alias Firefly.Discussion.{Policy, Post, Thread}
  alias Firefly.Notifications.{EmailWorker, Subscriptions}

  @doc "Whether the site offers mailing list mode."
  def enabled?, do: SiteSettings.get("mailing_list_mode")

  @doc """
  The members `post` in `thread` goes to (see the moduledoc), `post.user`
  loaded.
  """
  def recipients(%Thread{} = thread, %Post{} = post) do
    if enabled?(), do: readers(thread, post, candidates(post)), else: []
  end

  # Members in mailing list mode who can get email, the author only with echo.
  defp candidates(post) do
    User
    |> where([u], u.mailing_list_mode and not is_nil(u.confirmed_at) and not is_nil(u.email))
    |> where([u], is_nil(u.deleted_at) and is_nil(u.plugin_bot))
    |> where([u], u.id != ^(post.user_id || 0) or not u.mailing_list_no_echo)
    |> Repo.all()
    |> Enum.reject(&User.suspended?/1)
  end

  # Those who may read the thread, don't mute the author and didn't mute it.
  defp readers(thread, post, candidates) do
    readers = thread |> Policy.thread_readers(candidates) |> MapSet.new(& &1.id)
    muters = Ignores.muters(post.user_id, Enum.map(candidates, & &1.id))

    Enum.filter(candidates, fn user ->
      MapSet.member?(readers, user.id) and not MapSet.member?(muters, user.id) and
        Subscriptions.effective_thread_level(user, thread) != "muted"
    end)
  end

  @doc """
  Emails `post` to its recipients, within each one's daily limit. Returns
  the ids of every recipient (whether or not the limit let it through),
  who get no other email about it.
  """
  def deliver(%Thread{} = thread, %Post{} = post) do
    recipients = recipients(thread, post)

    for user <- recipients, take_quota(user) == :ok do
      send_email(user, thread, post)
    end

    Enum.map(recipients, & &1.id)
  end

  # Counts one email against today's limit, if there's room.
  defp take_quota(%User{id: id}) do
    today = Date.utc_today()
    max = SiteSettings.get("max_mailing_list_emails_per_day")

    {count, _} =
      User
      |> where([u], u.id == ^id)
      |> where(
        [u],
        u.mailing_list_sent_on != ^today or is_nil(u.mailing_list_sent_on) or
          u.mailing_list_sent_count < ^max
      )
      |> update([u],
        set: [
          mailing_list_sent_count:
            fragment(
              "CASE WHEN ? = ? THEN ? + 1 ELSE 1 END",
              u.mailing_list_sent_on,
              ^today,
              u.mailing_list_sent_count
            ),
          mailing_list_sent_on: ^today
        ]
      )
      |> Repo.update_all([])

    if count == 1, do: :ok, else: :limit
  end

  # Each email is its own job (see Firefly.Notifications.EmailWorker): one
  # failed address doesn't hold up the rest, and none goes twice.
  defp send_email(user, thread, post), do: EmailWorker.mailing_list_later(user, thread, post)
end
