defmodule FirestormWeb.Emails do
  @moduledoc """
  Module hosting outbound email templates.
  """

  import Bamboo.Email
  alias FirestormWeb.Markdown
  alias FirestormWeb.Forums.{Post, Thread, User}

  def thread_new_post_notification(%User{} = user, %Thread{} = thread, %Post{} = post) do
    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firestorm_web, :email)[:from])
    |> subject("There was a new post in a thread you are watching on Firefly")
    |> html_body(html_body_for(:reply, thread, post))
    |> text_body(text_body_for(:reply, thread, post))
    |> put_header("reply-to", FirestormWeb.ReplyAddress.address(thread, user))
  end

  def thread_created_notification(%User{} = user, %Thread{} = thread, %Post{} = post) do
    new_email()
    |> to(user.email)
    |> from(Application.fetch_env!(:firestorm_web, :email)[:from])
    |> subject("A new thread was started in a category you are watching on Firefly")
    |> html_body(html_body_for(:new_thread, thread, post))
    |> text_body(text_body_for(:new_thread, thread, post))
    |> put_header("reply-to", FirestormWeb.ReplyAddress.address(thread, user))
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

  defp html_body_for(:reply, %Thread{} = thread, %Post{} = post) do
    html_body_for(
      "The Firefly thread #{link(thread.title, thread_url(thread))} has received #{link("a reply", post_url(thread, post))}:",
      "this thread or its category",
      post
    )
  end

  defp html_body_for(:new_thread, %Thread{} = thread, %Post{} = post) do
    html_body_for(
      "A new Firefly thread was started: #{link(thread.title, thread_url(thread))}",
      "its category",
      post
    )
  end

  defp html_body_for(intro, watched, post) do
    """
    <p>#{intro}</p>
    <hr />
    #{Markdown.render(post.body)}
    <hr />
    <p><small>You're getting this because you watch #{watched}. We won't email you about this thread again until you've read it. #{link("Change your notification settings", settings_url())}.</small></p>
    """
  end

  defp settings_url, do: FirestormWeb.Web.Paths.notification_settings_url()

  defp text_body_for(:reply, %Thread{} = thread, %Post{} = post) do
    text_body_for(
      "The Firefly thread #{thread.title} [#{thread_url(thread)}] has received a reply [#{post_url(thread, post)}]:",
      "this thread or its category",
      post
    )
  end

  defp text_body_for(:new_thread, %Thread{} = thread, %Post{} = post) do
    text_body_for(
      "A new Firefly thread was started: #{thread.title} [#{thread_url(thread)}]",
      "its category",
      post
    )
  end

  defp text_body_for(intro, watched, post) do
    """
    #{intro}\n\n
    #{post.body}

    --
    You're getting this because you watch #{watched}. We won't email you about this thread again until you've read it.
    Change your notification settings: #{settings_url()}
    """
  end

  defp link(text, url) do
    ~s(<a href="#{escape(url)}">#{escape(text)}</a>)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
