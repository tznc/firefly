defmodule Firefly.Notifications.Emails do
  @moduledoc """
  Module hosting outbound email templates. They call the site by its `title`
  site setting.
  """

  import Swoosh.Email
  alias Firefly.Rendering.Markdown
  alias Firefly.SiteSettings
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
      reason: @watching,
      template: "thread_new_post_notification"
    )
  end

  def thread_created_notification(%User{} = user, %Thread{} = thread, %Post{} = post) do
    post_notification(user, thread, post,
      subject: "A new thread was started in a category you are watching on Firefly",
      html: "A new Firefly thread was started: #{link(thread.title, thread_url(thread))}",
      text: "A new Firefly thread was started: #{thread.title} [#{thread_url(thread)}]",
      reason: @watching_category,
      template: "thread_created_notification"
    )
  end

  @doc """
  `post` in `thread`, for `user` in mailing list mode (see
  `Firefly.Notifications.MailingList`; `post.user` loaded): the post itself,
  with the thread's title as the subject so a mail client threads them.
  """
  def mailing_list_post(%User{} = user, %Thread{} = thread, %Post{} = post) do
    author = if post.user, do: "@" <> post.user.username, else: "Someone"
    url = post_url(thread, post)

    new()
    |> put_private(:template, "mailing_list_post")
    |> recipient(user.email)
    |> from(sender())
    |> subject("[#{site()}] #{thread.title}")
    |> html_body("""
    <p>#{escape(author)} #{link("posted", url)} in #{link(thread.title, thread_url(thread))}:</p>
    <hr />
    #{Markdown.render(post.body)}
    <hr />
    <p><small>You're getting every post because mailing list mode is on. Reply to this email to answer in the thread. #{link("Change your notification settings", settings_url())}.</small></p>
    """)
    |> text_body("""
    #{author} posted [#{url}] in #{thread.title} [#{thread_url(thread)}]:

    #{post.body}

    --
    You're getting every post because mailing list mode is on. Reply to this email to answer in the thread.
    Change your notification settings: #{settings_url()}
    """)
    |> reply_to(Firefly.Notifications.ReplyAddress.address(thread, user))
    |> header("List-Id", "#{site()} <list.#{URI.parse(Firefly.Endpoint.url()).host}>")
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
      reason: @mentioned,
      template: "mention_notification"
    )
  end

  defp post_notification(user, thread, post, parts) do
    new()
    |> put_private(:template, parts[:template])
    |> recipient(user.email)
    |> from(sender())
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
    |> reply_to(Firefly.Notifications.ReplyAddress.address(thread, user))
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

    new()
    |> put_private(:template, "message_notification")
    |> recipient(user.email)
    |> from(sender())
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

  @doc """
  A chat message for `user`, who's away: a mention, or a direct message
  (`subject` says which). `url` opens it in chat.
  """
  def chat_notification(%User{} = user, subject, body, url) do
    new()
    |> put_private(:template, "chat_notification")
    |> recipient(user.email)
    |> from(sender())
    |> subject("#{subject} on #{site()}")
    |> html_body("""
    <p>#{escape(subject)}. #{link("Open it in chat", url)}:</p>
    <hr />
    #{Markdown.render(body)}
    <hr />
    <p><small>You're getting this because you weren't on #{escape(site())} when it was sent. We won't email you about this chat again until you've read it. #{link("Change your notification settings", settings_url())}.</small></p>
    """)
    |> text_body("""
    #{subject}. Open it in chat: #{url}

    #{body}

    --
    You're getting this because you weren't on #{site()} when it was sent. We won't email you about this chat again until you've read it.
    Change your notification settings: #{settings_url()}
    """)
  end

  @doc "Tells `user` they were silenced or suspended (`subject` says which and until when)."
  def penalty(%User{} = user, subject, reason) do
    new()
    |> put_private(:template, "penalty")
    |> recipient(user.email)
    |> from(sender())
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
    new()
    |> put_private(:template, "invite")
    |> recipient(email)
    |> from(sender())
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
    new()
    |> put_private(:template, "confirmation")
    |> recipient(user.email)
    |> from(sender())
    |> subject("Confirm your email address for #{site()}")
    |> html_body("""
    <p>Hi #{escape(user.username)},</p>
    <p>Confirm your email address to start posting on #{escape(site())}: #{link("confirm my email", url)}</p>
    <p>The link expires in #{SiteSettings.get("email_confirmation_days")} days. If you didn't create a #{escape(site())} account, ignore this email.</p>
    """)
    |> text_body("""
    Hi #{user.username},

    Confirm your email address to start posting on #{site()}:

    #{url}

    The link expires in #{SiteSettings.get("email_confirmation_days")} days. If you didn't create a #{site()} account, ignore this email.
    """)
  end

  def password_reset(%User{} = user, url) do
    new()
    |> put_private(:template, "password_reset")
    |> recipient(user.email)
    |> from(sender())
    |> subject("Reset your #{site()} password")
    |> html_body("""
    <p>Hi #{escape(user.username)},</p>
    <p>Someone asked to reset the password for your #{escape(site())} account. #{link("Choose a new password", url)}.</p>
    <p>The link expires in #{hours(SiteSettings.get("password_reset_hours"))} and works once. If it wasn't you, ignore this email.</p>
    """)
    |> text_body("""
    Hi #{user.username},

    Someone asked to reset the password for your #{site()} account. Choose a new password here:

    #{url}

    The link expires in #{hours(SiteSettings.get("password_reset_hours"))} and works once. If it wasn't you, ignore this email.
    """)
  end

  @doc "A one-time login link (`user`), or a sign-up link for `email` (no user yet)."
  def magic_link(user_or_email, url) do
    {address, greeting, action} =
      case user_or_email do
        %User{} = user -> {user.email, "Hi #{user.username},", "log in to"}
        email -> {email, "Hi,", "create your account on"}
      end

    new()
    |> put_private(:template, "magic_link")
    |> recipient(address)
    |> from(sender())
    |> subject("Your #{site()} login link")
    |> html_body("""
    <p>#{escape(greeting)}</p>
    <p>Use this link to #{action} #{escape(site())}: #{link("log me in", url)}</p>
    <p>It expires in #{SiteSettings.get("magic_link_minutes")} minutes and works once. If you didn't ask for it, ignore this email.</p>
    """)
    |> text_body("""
    #{greeting}

    Use this link to #{action} #{site()}:

    #{url}

    It expires in #{SiteSettings.get("magic_link_minutes")} minutes and works once. If you didn't ask for it, ignore this email.
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

    new()
    |> put_private(:template, "digest")
    |> recipient(user.email)
    |> from(sender())
    |> subject("[#{site()}] Summary since #{since}")
    |> header("List-Unsubscribe", "<#{unsubscribe}>")
    |> header("List-Unsubscribe-Post", "List-Unsubscribe=One-Click")
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

  @doc "A test email to `address`, which staff send from `/staff/emails` to check delivery."
  def test_email(address) do
    new()
    |> put_private(:template, "test_email")
    |> recipient(address)
    |> from(sender())
    |> subject("Test email from #{site()}")
    |> html_body("""
    <p>This is a test email from #{link(site(), Firefly.Endpoint.url())}.</p>
    <p>If you're reading it, email delivery works.</p>
    """)
    |> text_body("""
    This is a test email from #{site()} (#{Firefly.Endpoint.url()}).

    If you're reading it, email delivery works.
    """)
  end

  @doc """
  Every template built with sample data (no database), for staff to
  preview at `/staff/emails`: `{template, email}` pairs, in the order the
  templates appear here.
  """
  def previews do
    user = %User{id: 1, username: "ada", name: "Ada", email: "ada@example.com"}
    author = %User{id: 2, username: "grace", name: "Grace", email: "grace@example.com"}
    category = %Firefly.Discussion.Category{id: 1, title: "General"}

    thread = %Thread{id: 1, category_id: 1, title: "Welcome to the forum", category: category}

    post = %Post{
      id: 2,
      thread_id: 1,
      body: "Hello **everyone**! Glad to be here. Has anyone tried @ada's tip yet?",
      user: author,
      thread: thread
    }

    conversation = %Conversation{id: 1, title: "Meetup plans"}
    message = %Message{id: 1, body: "Are you coming on **Friday**?"}
    url = Firefly.Endpoint.url() <> "/example-link"

    digest = %{
      since: DateTime.add(DateTime.utc_now(:second), -7, :day),
      threads: [thread],
      new_posts: 12,
      replies: [post],
      notifications:
        {3,
         [%Firefly.Notifications.Notification{subject: "@grace replied in Welcome to the forum"}]}
    }

    [
      {"thread_new_post_notification", thread_new_post_notification(user, thread, post)},
      {"thread_created_notification", thread_created_notification(user, thread, post)},
      {"mailing_list_post", mailing_list_post(user, thread, post)},
      {"mention_notification", mention_notification(user, thread, post)},
      {"message_notification",
       message_notification(user, conversation, message, "@grace sent you a message")},
      {"chat_notification",
       chat_notification(user, "@grace mentioned you in #general", "Hi @ada, look at this!", url)},
      {"penalty",
       penalty(user, "You were silenced for 1 day", "Posting the same link everywhere.")},
      {"invite", invite(%{email: "friend@example.com", invited_by: author}, url)},
      {"confirmation", confirmation(user, url)},
      {"password_reset", password_reset(user, url)},
      {"magic_link", magic_link(user, url)},
      {"digest", digest(user, digest, url)},
      {"test_email", test_email(user.email)}
    ]
  end

  defdelegate thread_url(thread), to: Firefly.URLs

  def post_url(thread, post) do
    "#{thread_url(thread)}#post-#{post.id}"
  end

  # The site's name (the `title` site setting).
  defp site, do: SiteSettings.get("title")

  defp hours(1), do: "an hour"
  defp hours(n), do: "#{n} hours"

  # An address that's missing (an account without one) leaves the email
  # without a recipient: the mailer logs it as skipped.
  defp recipient(email, address) when address in [nil, ""], do: email
  defp recipient(email, address), do: to(email, address)

  # The deployment's sender address, named as the `email_from_name` setting says.
  defp sender do
    {_name, address} = Application.fetch_env!(:firefly, :email)[:from]
    {SiteSettings.get("email_from_name"), address}
  end

  defp settings_url, do: Firefly.URLs.notification_settings_url()

  defp link(text, url) do
    ~s(<a href="#{escape(url)}">#{escape(text)}</a>)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
