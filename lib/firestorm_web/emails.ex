defmodule FirestormWeb.Emails do
  @moduledoc """
  Module hosting outbound email templates.
  """

  import Bamboo.Email
  alias FirestormWeb.Markdown
  alias FirestormWeb.Forums.{Conversation, Message, Post, Thread, User}

  @watching "You're getting this because you watch this thread, its category or one of its tags."
  @mentioned "You're getting this because you were mentioned."

  def thread_new_post_notification(%User{} = user, %Thread{} = thread, %Post{} = post) do
    reply = post_url(thread, post)

    post_notification(user, thread, post,
      subject: "There was a new post in a thread you are watching on Firefly",
      html:
        "The Firefly thread #{link(thread.title, thread_url(thread))} has received #{link("a reply", reply)}:",
      text:
        "The Firefly thread #{thread.title} [#{thread_url(thread)}] has received a reply [#{reply}]:",
      reason: @watching
    )
  end

  @doc "`post` in `thread` mentions `user` (`post.user` must be loaded)."
  def mention_notification(%User{} = user, %Thread{} = thread, %Post{} = post) do
    author = "@" <> post.user.username
    mention = post_url(thread, post)

    post_notification(user, thread, post,
      subject: "#{author} mentioned you on Firefly",
      html:
        "#{escape(author)} #{link("mentioned you", mention)} in the Firefly thread #{link(thread.title, thread_url(thread))}:",
      text:
        "#{author} mentioned you [#{mention}] in the Firefly thread #{thread.title} [#{thread_url(thread)}]:",
      reason: @mentioned
    )
  end

  defp post_notification(user, thread, post, parts) do
    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firestorm_web, :email)[:from])
    |> subject(parts[:subject])
    |> html_body("""
    <p>#{parts[:html]}</p>
    <hr />
    #{Markdown.render(post.body)}
    <hr />
    <p><small>#{parts[:reason]} We won't email you about this thread again until you've read it. #{link("Change your notification settings", settings_url())}.</small></p>
    """)
    |> text_body("""
    #{parts[:text]}\n\n
    #{post.body}

    --
    #{parts[:reason]} We won't email you about this thread again until you've read it.
    Change your notification settings: #{settings_url()}
    """)
    |> put_header("reply-to", FirestormWeb.ReplyAddress.address(thread, user))
  end

  @doc """
  A private `message` for `user` (`subject` says who sent it). It has no
  reply-by-email address: those are for threads, and a reply must come from
  the site, where only participants can post.
  """
  def message_notification(
        %User{} = user,
        %Conversation{} = conversation,
        %Message{} = message,
        subject
      ) do
    url = "#{FirestormWeb.Web.Paths.conversation_url(conversation)}#message-#{message.id}"

    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firestorm_web, :email)[:from])
    |> subject("#{subject} on Firefly")
    |> html_body("""
    <p>#{escape(subject)}. #{link("Read and reply on Firefly", url)}:</p>
    <hr />
    #{Markdown.render(message.body)}
    <hr />
    <p><small>You're getting this because you're in this private conversation. We won't email you about it again until you've read it. #{link("Change your notification settings", settings_url())}.</small></p>
    """)
    |> text_body("""
    #{subject}. Read and reply on Firefly: #{url}

    #{message.body}

    --
    You're getting this because you're in this private conversation. We won't email you about it again until you've read it.
    Change your notification settings: #{settings_url()}
    """)
  end

  def confirmation(%User{} = user, url) do
    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firestorm_web, :email)[:from])
    |> subject("Confirm your email address for Firefly")
    |> html_body("""
    <p>Hi #{escape(user.username)},</p>
    <p>Confirm your email address to start posting on Firefly: #{link("confirm my email", url)}</p>
    <p>The link expires in 7 days. If you didn't create a Firefly account, ignore this email.</p>
    """)
    |> text_body("""
    Hi #{user.username},

    Confirm your email address to start posting on Firefly:

    #{url}

    The link expires in 7 days. If you didn't create a Firefly account, ignore this email.
    """)
  end

  def password_reset(%User{} = user, url) do
    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firestorm_web, :email)[:from])
    |> subject("Reset your Firefly password")
    |> html_body("""
    <p>Hi #{escape(user.username)},</p>
    <p>Someone asked to reset the password for your Firefly account. #{link("Choose a new password", url)}.</p>
    <p>The link expires in an hour and works once. If it wasn't you, ignore this email.</p>
    """)
    |> text_body("""
    Hi #{user.username},

    Someone asked to reset the password for your Firefly account. Choose a new password here:

    #{url}

    The link expires in an hour and works once. If it wasn't you, ignore this email.
    """)
  end

  defdelegate thread_url(thread), to: FirestormWeb.Web.Paths

  def post_url(thread, post) do
    "#{thread_url(thread)}#post-#{post.id}"
  end

  defp settings_url, do: FirestormWeb.Web.Paths.notification_settings_url()

  defp link(text, url) do
    ~s(<a href="#{escape(url)}">#{escape(text)}</a>)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
