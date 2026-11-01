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
    |> html_body(html_body_for(thread, post))
    |> text_body(text_body_for(thread, post))
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

  defdelegate thread_url(thread), to: FirestormWeb.Web.Paths

  def post_url(thread, post) do
    "#{thread_url(thread)}#post-#{post.id}"
  end

  defp html_body_for(%Thread{} = thread, %Post{} = post) do
    """
    <p>The Firefly thread #{link(thread.title, thread_url(thread))} has received #{link("a reply", post_url(thread, post))}:</p>
    <hr />
    #{Markdown.render(post.body)}
    """
  end

  defp text_body_for(%Thread{} = thread, %Post{} = post) do
    """
    The Firefly thread #{thread.title} [#{thread_url(thread)}] has received a reply [#{post_url(thread, post)}]:\n\n
    #{post.body}
    """
  end

  defp link(text, url) do
    ~s(<a href="#{escape(url)}">#{escape(text)}</a>)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
