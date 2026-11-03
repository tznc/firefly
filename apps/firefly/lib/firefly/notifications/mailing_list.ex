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
  notifications stay. The emails go out from the notifications fan-out
  process (`Firefly.Notifications.Dispatcher`), after the post is saved.
  """

  import Ecto.Query

  alias Firefly.{Mailer, Repo, SiteSettings}
  alias Firefly.Accounts.{Ignores, User}
  alias Firefly.Discussion.{Policy, Post, Thread}
  alias Firefly.Notifications.{Emails, Subscriptions}

  require Logger

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

  # One failed address doesn't stop the rest.
  defp send_email(user, thread, post) do
    case user |> Emails.mailing_list_post(thread, post) |> Mailer.deliver_now() do
      {:ok, _email} -> :ok
      {:error, error} -> failed(user, error)
    end
  rescue
    error -> failed(user, error)
  end

  defp failed(user, error),
    do: Logger.error("Mailing list email to user #{user.id} failed: #{inspect(error)}")
end
