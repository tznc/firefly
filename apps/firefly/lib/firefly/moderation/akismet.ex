defmodule Firefly.Moderation.Akismet do
  @moduledoc """
  Spam checks with [Akismet](https://akismet.com): with the `akismet_enabled`
  setting on and an API key (`akismet_api_key`), new posts, private
  messages, chat messages and profile edits (each kind its own setting) by
  members below the `akismet_trust_level` trust level are sent to
  Akismet's `comment-check` in the background. Posting never waits for
  it, nor fails with it: errors are logged and the content stands.

  Akismet's spam:

    * a post is flagged (reason spam, "Akismet") and hidden pending review
      (see `Firefly.Moderation.Flags.hide_by_system/3`). A post AI triage
      (see `Firefly.AI.Triage`) flagged too stays one item in the queue:
      system flags on a post merge;
    * a chat message is flagged into the queue (see `Firefly.Chat`);
    * a private message or a profile waits in the queue's Akismet section.

  Staff decide in the review queue as for any flag; whatever they decide
  about content Akismet checked is reported back (`submit-spam` when they
  agree it's spam, Akismet missed it included; `submit-ham` when it
  wasn't), which trains Akismet for the site. For private messages and
  profiles, "Confirm spam" deletes the message or clears the profile's
  bio, website and location; "Not spam" leaves them. Detections and those
  decisions go to the staff log. Every verdict is kept
  (`Firefly.Moderation.AkismetCheck`) for the reports.

  The request's client (IP address, user agent, referrer), which Akismet
  weighs, is what the web layer recorded for the process that posted
  (`put_client/1`).
  """

  import Ecto.Query

  require Logger

  alias Firefly.{Accounts, Chat, Discussion, Endpoint, Repo, SiteSettings, TrustLevels, URLs}
  alias Firefly.Accounts.User
  alias Firefly.Discussion.Post
  alias Firefly.Messaging.Message
  alias Firefly.Moderation.{AkismetCheck, Flags, Review, StaffLog}

  @base_url "https://rest.akismet.com/1.1"
  @client_key {__MODULE__, :client}
  @settings %{
    "post" => "akismet_check_posts",
    "message" => "akismet_check_messages",
    "chat" => "akismet_check_chat",
    "profile" => "akismet_check_profiles"
  }

  @doc "The note on the flags Akismet raises."
  def flag_note, do: "Akismet: spam"

  @doc "Whether `flag` (a post's or a chat message's) came from Akismet."
  def flag?(%{user_id: nil, note: note}) when is_binary(note),
    do: String.contains?(note, flag_note())

  def flag?(_flag), do: false

  defp config, do: Application.get_env(:firefly, __MODULE__, [])

  @doc "Whether checks are on: the setting, with an API key."
  def enabled?,
    do:
      SiteSettings.get("akismet_enabled") and
        String.trim(SiteSettings.get("akismet_api_key")) != ""

  @doc """
  Remembers the client of the current request (`ip`, `user_agent`,
  `referrer`) for checks of what this process posts.
  """
  def put_client(client), do: Process.put(@client_key, client)

  @doc """
  The client `put_client/1` remembered for this process (`%{}` if none),
  also what screened IPs are checked against (see
  `Firefly.Moderation.Screening`).
  """
  def client, do: Process.get(@client_key, %{})

  ## Checking

  @doc "A post was created by `user` (queued posts wait for staff anyway)."
  def posted(%Post{} = post, %User{} = user) do
    if is_nil(post.queued_at) do
      post = Repo.preload(post, :thread)

      check_later("post", post.id, user, %{
        "comment_type" => if(Discussion.first_post?(post), do: "forum-post", else: "reply"),
        "comment_content" => post.body,
        "permalink" => "#{URLs.thread_url(post.thread)}#post-#{post.id}"
      })
    end

    :ok
  end

  @doc "A private message was sent by `user`."
  def message_sent(%Message{} = message, %User{} = user) do
    check_later("message", message.id, user, %{
      "comment_type" => "message",
      "comment_content" => message.body
    })
  end

  @doc "A chat message was sent by `user`."
  def chat_sent(message, %User{} = user) do
    check_later("chat", message.id, user, %{
      "comment_type" => "message",
      "comment_content" => message.body
    })
  end

  @doc "`user` changed their profile's bio, website or location."
  def profile_updated(%User{} = user) do
    content = Enum.reject([user.bio, user.website, user.location], &(&1 in [nil, ""]))

    if content == [],
      do: :ok,
      else:
        check_later("profile", user.id, user, %{
          "comment_type" => "signup",
          "comment_content" => Enum.join(content, "\n"),
          "comment_author_url" => user.website,
          "permalink" => URLs.user_url(user)
        })
  end

  # Members at or above the trust level, and admins, aren't checked.
  defp check_later(kind, id, user, fields) do
    if enabled?() and SiteSettings.get(@settings[kind]) and not exempt?(user) do
      params =
        %{
          "blog" => Endpoint.url(),
          "user_ip" => client()[:ip],
          "user_agent" => client()[:user_agent],
          "referrer" => client()[:referrer],
          "comment_author" => user.username,
          "comment_author_email" => user.email
        }
        |> Map.merge(fields)
        |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

      background(fn -> check(kind, id, user, params) end)
    end

    :ok
  end

  defp exempt?(user),
    do:
      TrustLevels.at_least?(user, SiteSettings.get("akismet_trust_level")) or
        Accounts.admin?(user)

  defp background(fun) do
    if config()[:async] == false do
      fun.()
    else
      {:ok, _pid} =
        Task.Supervisor.start_child(
          Firefly.Moderation.Akismet.TaskSupervisor,
          Firefly.Telemetry.bind(fun)
        )
    end

    :ok
  end

  @doc """
  Asks Akismet about content `kind` `id` by `user` (`params`, as
  `comment-check` takes them), records the verdict and acts on spam.
  """
  def check(kind, id, user, params) do
    case request("comment-check", params) do
      {:ok, "true"} -> record(kind, id, user, params, true)
      {:ok, "false"} -> record(kind, id, user, params, false)
      other -> Logger.warning("Akismet check of #{kind} #{id} failed: #{inspect(other)}")
    end

    :ok
  end

  defp record(kind, id, user, params, spam?) do
    check =
      Repo.insert!(%AkismetCheck{
        kind: kind,
        subject_id: id,
        user_id: user.id,
        spam: spam?,
        status: if(spam?, do: "pending", else: "clean"),
        params: params
      })

    if spam?, do: caught(check, user)
  end

  defp caught(check, user) do
    StaffLog.record_system("akismet.spam", user, %{
      kind: check.kind,
      id: check.subject_id,
      username: user.username,
      excerpt: String.slice(check.params["comment_content"] || "", 0, 200)
    })

    case check.kind do
      "post" ->
        if post = Repo.get(Post, check.subject_id),
          do: Flags.hide_by_system(post, flag_note(), "spam")

      "chat" ->
        if message = Chat.get_message(check.subject_id),
          do: Chat.flag_by_system(message, flag_note(), "spam")

      _queued_here ->
        Review.changed()
    end
  end

  ## Feedback

  @doc """
  Staff decided about flagged post `post_id` (`:spam` when they agreed,
  `:ham` when they didn't): reported to Akismet if it checked the post.
  """
  def post_reviewed(post_id, verdict), do: reviewed("post", post_id, verdict)

  @doc "Staff decided about flagged chat message `message_id` (as `post_reviewed/2`)."
  def chat_reviewed(message_id, verdict), do: reviewed("chat", message_id, verdict)

  defp reviewed(kind, id, verdict) do
    if check = latest(kind, id) do
      status =
        cond do
          not check.spam -> check.status
          verdict == :spam -> "confirmed"
          true -> "not_spam"
        end

      check
      |> Ecto.Changeset.change(status: status, reviewed_at: DateTime.utc_now(:second))
      |> Repo.update!()

      feedback(check, verdict)
    end

    :ok
  end

  defp latest(kind, id) do
    Repo.one(
      from(c in AkismetCheck,
        where: c.kind == ^kind and c.subject_id == ^id,
        order_by: [desc: c.id],
        limit: 1
      )
    )
  end

  # Reported once, in the background.
  defp feedback(check, verdict) do
    verdict = Atom.to_string(verdict)

    case Repo.update_all(
           from(c in AkismetCheck, where: c.id == ^check.id and is_nil(c.feedback)),
           set: [feedback: verdict]
         ) do
      {1, _} -> background(fn -> submit(verdict, check.params) end)
      {0, _} -> :ok
    end
  end

  defp submit(verdict, params) do
    case request("submit-#{verdict}", params) do
      {:ok, _thanks} -> :ok
      other -> Logger.warning("Akismet submit-#{verdict} failed: #{inspect(other)}")
    end
  end

  ## The review queue's Akismet section

  @doc "Private messages and profiles Akismet called spam, waiting for staff, oldest first."
  def pending do
    Repo.all(
      from(c in AkismetCheck,
        where: c.status == "pending" and c.kind in ["message", "profile"],
        order_by: [asc: c.id],
        preload: :user
      )
    )
  end

  @doc "How many items wait in the review queue's Akismet section."
  def pending_count do
    Repo.aggregate(
      from(c in AkismetCheck, where: c.status == "pending" and c.kind in ["message", "profile"]),
      :count
    )
  end

  @doc """
  Decides a pending private message or profile as `admin`: `:spam`
  (confirmed: the message is deleted, the profile's bio, website and
  location cleared) or `:ham`. Reported to Akismet and logged.
  `{:error, :not_pending}` when someone already decided.
  """
  def review(check_id, %User{} = admin, verdict) when verdict in [:spam, :ham] do
    status = if verdict == :spam, do: "confirmed", else: "not_spam"
    now = DateTime.utc_now(:second)

    result = Repo.transact(fn -> decide(check_id, admin, verdict, status, now) end)

    with {:ok, check} <- result do
      feedback(check, verdict)
      Review.changed()
      {:ok, check}
    end
  end

  defp decide(check_id, admin, verdict, status, now) do
    case Repo.update_all(
           from(c in AkismetCheck, where: c.id == ^check_id and c.status == "pending", select: c),
           set: [status: status, reviewed_by_id: admin.id, reviewed_at: now]
         ) do
      {1, [check]} ->
        if verdict == :spam, do: remove(check)
        log(admin, verdict, check)
        {:ok, check}

      {0, _} ->
        {:error, :not_pending}
    end
  end

  defp remove(%AkismetCheck{kind: "message", subject_id: id}),
    do: Repo.delete_all(where(Message, id: ^id))

  defp remove(%AkismetCheck{kind: "profile", subject_id: id}),
    do: Repo.update_all(where(User, id: ^id), set: [bio: nil, website: nil, location: nil])

  defp log(admin, verdict, check) do
    user = check.user_id && Repo.get(User, check.user_id)

    StaffLog.record(
      admin,
      if(verdict == :spam, do: "akismet.confirm", else: "akismet.not_spam"),
      user || {"akismet_check", check.id},
      %{
        kind: check.kind,
        id: check.subject_id,
        username: user && user.username,
        excerpt: String.slice(check.params["comment_content"] || "", 0, 200)
      }
    )
  end

  ## Akismet's API

  @doc "Whether the API key is valid for this site (`verify-key`)."
  def verify_key do
    case request("verify-key", %{"blog" => Endpoint.url()}) do
      {:ok, "valid"} -> :ok
      {:ok, _invalid} -> {:error, :invalid_key}
      error -> error
    end
  end

  defp request(call, params) do
    url = "#{config()[:base_url] || @base_url}/#{call}"
    form = Map.put(params, "api_key", String.trim(SiteSettings.get("akismet_api_key")))

    case Req.post(url, form: form, receive_timeout: 10_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, String.trim(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "A message for an error from `review/3`."
  def message(:not_pending), do: "Someone already reviewed that."
end
