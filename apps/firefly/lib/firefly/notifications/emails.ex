defmodule Firefly.Notifications.Emails do
  @moduledoc """
  Module hosting outbound email templates. They call the site by its `title`
  site setting.
  """

  import Bamboo.Email
  alias Firefly.Rendering.Markdown
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Post, Thread}
  alias Firefly.Messaging.{Conversation, Message}

  @watching "You're getting this because you watch this thread, its category or one of its tags."
  @mentioned "You're getting this because you were mentioned."
  @watching_category "You're getting this because you watch its category."

  def thread_new_post_notification(%User{} = user, %Thread{} = thread, %Post{} = post) do
    reply = post_url(thread, post)

    post_notification(user, thread, post,
      subject: "There was a new post in a thread you are watching on #{site()}",
      html:
        "The #{escape(site())} thread #{link(thread.title, thread_url(thread))} has received #{link("a reply", reply)}:",
      text:
        "The #{site()} thread #{thread.title} [#{thread_url(thread)}] has received a reply [#{reply}]:",
      reason: @watching
    )
  end

  def thread_created_notification(%User{} = user, %Thread{} = thread, %Post{} = post) do
    post_notification(user, thread, post,
      subject: "A new thread was started in a category you are watching on Firefly",
      html: "A new Firefly thread was started: #{link(thread.title, thread_url(thread))}",
      text: "A new Firefly thread was started: #{thread.title} [#{thread_url(thread)}]",
      reason: @watching_category
    )
  end

  @doc "`post` in `thread` mentions `user` (`post.user` must be loaded)."
  def mention_notification(%User{} = user, %Thread{} = thread, %Post{} = post) do
    author = "@" <> post.user.username
    mention = post_url(thread, post)

    post_notification(user, thread, post,
      subject: "#{author} mentioned you on #{site()}",
      html:
        "#{escape(author)} #{link("mentioned you", mention)} in the #{escape(site())} thread #{link(thread.title, thread_url(thread))}:",
      text:
        "#{author} mentioned you [#{mention}] in the #{site()} thread #{thread.title} [#{thread_url(thread)}]:",
      reason: @mentioned
    )
  end

  defp post_notification(user, thread, post, parts) do
    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firefly, :email)[:from])
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
    |> put_header("reply-to", Firefly.Notifications.ReplyAddress.address(thread, user))
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
    url = "#{Firefly.URLs.conversation_url(conversation)}#message-#{message.id}"

    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firefly, :email)[:from])
    |> subject("#{subject} on #{site()}")
    |> html_body("""
    <p>#{escape(subject)}. #{link("Read and reply on #{site()}", url)}:</p>
    <hr />
    #{Markdown.render(message.body)}
    <hr />
    <p><small>You're getting this because you're in this private conversation. We won't email you about it again until you've read it. #{link("Change your notification settings", settings_url())}.</small></p>
    """)
    |> text_body("""
    #{subject}. Read and reply on #{site()}: #{url}

    #{message.body}

    --
    You're getting this because you're in this private conversation. We won't email you about it again until you've read it.
    Change your notification settings: #{settings_url()}
    """)
  end

  @doc "Tells `user` they were silenced or suspended (`subject` says which and until when)."
  def penalty(%User{} = user, subject, reason) do
    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firefly, :email)[:from])
    |> subject("#{subject} on #{site()}")
    |> html_body("""
    <p>Hi #{escape(user.username)},</p>
    <p>#{escape(subject)} on #{escape(site())}.</p>
    <p>Reason: #{escape(reason)}</p>
    """)
    |> text_body("""
    Hi #{user.username},

    #{subject} on #{site()}.

    Reason: #{reason}
    """)
  end

  @doc "An invitation to join, for `invite.email` (with its inviter loaded)."
  def invite(%{email: email, invited_by: %User{} = inviter}, url) do
    new_email()
    |> to(email)
    |> from(Application.fetch_env!(:firefly, :email)[:from])
    |> subject("#{inviter.username} invited you to join #{site()}")
    |> html_body("""
    <p>Hi,</p>
    <p>@#{escape(inviter.username)} invited you to join #{escape(site())}.</p>
    <p><a href="#{escape(url)}">Accept the invitation</a></p>
    """)
    |> text_body("""
    Hi,

    @#{inviter.username} invited you to join #{site()}.

    Accept the invitation: #{url}
    """)
  end

  def confirmation(%User{} = user, url) do
    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firefly, :email)[:from])
    |> subject("Confirm your email address for #{site()}")
    |> html_body("""
    <p>Hi #{escape(user.username)},</p>
    <p>Confirm your email address to start posting on #{escape(site())}: #{link("confirm my email", url)}</p>
    <p>The link expires in 7 days. If you didn't create a #{escape(site())} account, ignore this email.</p>
    """)
    |> text_body("""
    Hi #{user.username},

    Confirm your email address to start posting on #{site()}:

    #{url}

    The link expires in 7 days. If you didn't create a #{site()} account, ignore this email.
    """)
  end

  def password_reset(%User{} = user, url) do
    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firefly, :email)[:from])
    |> subject("Reset your #{site()} password")
    |> html_body("""
    <p>Hi #{escape(user.username)},</p>
    <p>Someone asked to reset the password for your #{escape(site())} account. #{link("Choose a new password", url)}.</p>
    <p>The link expires in an hour and works once. If it wasn't you, ignore this email.</p>
    """)
    |> text_body("""
    Hi #{user.username},

    Someone asked to reset the password for your #{site()} account. Choose a new password here:

    #{url}

    The link expires in an hour and works once. If it wasn't you, ignore this email.
    """)
  end

  @doc "A one-time login link (`user`), or a sign-up link for `email` (no user yet)."
  def magic_link(user_or_email, url) do
    {address, greeting, action} =
      case user_or_email do
        %User{} = user -> {user.email, "Hi #{user.username},", "log in to"}
        email -> {email, "Hi,", "create your account on"}
      end

    new_email()
    |> to(address)
    |> from(Application.fetch_env!(:firefly, :email)[:from])
    |> subject("Your #{site()} login link")
    |> html_body("""
    <p>#{escape(greeting)}</p>
    <p>Use this link to #{action} #{escape(site())}: #{link("log me in", url)}</p>
    <p>It expires in 15 minutes and works once. If you didn't ask for it, ignore this email.</p>
    """)
    |> text_body("""
    #{greeting}

    Use this link to #{action} #{site()}:

    #{url}

    It expires in 15 minutes and works once. If you didn't ask for it, ignore this email.
    """)
  end

  @doc """
  `user`'s digest (see `Firefly.Notifications.Digests.build/1`), with a one-click
  `unsubscribe` URL in the footer and the `List-Unsubscribe` headers.
  """
  def digest(%User{} = user, digest, unsubscribe) do
    %{threads: threads, new_posts: new_posts, replies: replies} = digest
    {unread, notifications} = digest.notifications
    since = Calendar.strftime(digest.since, "%b %-d")

    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firefly, :email)[:from])
    |> subject("[#{site()}] Summary since #{since}")
    |> put_header("List-Unsubscribe", "<#{unsubscribe}>")
    |> put_header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
    |> html_body("""
    <p>Hi #{escape(user.username)}, here's what you missed on #{link(site(), Firefly.Endpoint.url())} since #{since}.</p>
    #{digest_counts_html(new_posts, unread)}
    #{digest_section_html("Popular new threads", threads, fn t -> link(t.title, thread_url(t)) <> " <small>in #{escape(t.category.title)}</small>" end)}
    #{digest_section_html("Popular replies", replies, fn p -> "#{link(p.thread.title, post_url(p.thread, p))} <small>by @#{escape(p.user.username)}</small>" end)}
    #{digest_section_html("Your unread notifications", notifications, &escape(&1.subject))}
    <hr />
    <p><small>You're getting this because you haven't visited in a while. #{link("Change how often", settings_url())} or #{link("unsubscribe from digests", unsubscribe)}.</small></p>
    """)
    |> text_body("""
    Hi #{user.username}, here's what you missed on #{site()} since #{since}.

    #{new_posts} new posts, #{unread} unread notifications.
    #{digest_section_text("Popular new threads", threads, &"#{&1.title} [#{thread_url(&1)}]")}#{digest_section_text("Popular replies", replies, &"#{&1.thread.title}, by @#{&1.user.username} [#{post_url(&1.thread, &1)}]")}#{digest_section_text("Your unread notifications", notifications, & &1.subject)}
    --
    You're getting this because you haven't visited in a while.
    Change how often: #{settings_url()}
    Unsubscribe from digests: #{unsubscribe}
    """)
  end

  defp digest_counts_html(new_posts, unread),
    do:
      "<p><strong>#{new_posts}</strong> new posts · <strong>#{unread}</strong> unread notifications</p>"

  defp digest_section_html(_title, [], _item), do: ""

  defp digest_section_html(title, items, item) do
    "<h3>#{escape(title)}</h3><ul>" <> Enum.map_join(items, &"<li>#{item.(&1)}</li>") <> "</ul>"
  end

  defp digest_section_text(_title, [], _item), do: ""

  defp digest_section_text(title, items, item),
    do: "\n#{title}:\n" <> Enum.map_join(items, &"- #{item.(&1)}\n")

  defdelegate thread_url(thread), to: Firefly.URLs

  def post_url(thread, post) do
    "#{thread_url(thread)}#post-#{post.id}"
  end

  # The site's name (the `title` site setting).
  defp site, do: Firefly.SiteSettings.get("title")

  defp settings_url, do: Firefly.URLs.notification_settings_url()

  defp link(text, url) do
    ~s(<a href="#{escape(url)}">#{escape(text)}</a>)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
