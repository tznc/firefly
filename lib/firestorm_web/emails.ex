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
    |> from("noreply@firestormforum.org")
    |> subject("There was a new post in a thread you are watching on Firestorm")
    |> html_body(html_body_for(thread, post))
    |> text_body(text_body_for(thread, post))
    |> put_header("reply-to", reply_to_thread_address(thread))
  end

  defp reply_to_thread_address(%{id: id}) do
    "reply-thread-#{id}@#{inbound_email_domain()}"
  end

  defp inbound_email_domain do
    # This goes into config at some point
    "notifier.firestormforum.org"
  end

  defdelegate thread_url(thread), to: FirestormWeb.Web.Paths

  def post_url(thread, post) do
    "#{thread_url(thread)}#post-#{post.id}"
  end

  defp html_body_for(%Thread{} = thread, %Post{} = post) do
    """
    <p>The Firestorm thread #{link(thread.title, thread_url(thread))} has received #{link("a reply", post_url(thread, post))}:</p>
    <hr />
    #{Markdown.render(post.body)}
    """
  end

  defp text_body_for(%Thread{} = thread, %Post{} = post) do
    """
    The Firestorm thread #{thread.title} [#{thread_url(thread)}] has received a reply [#{post_url(thread, post)}]:\n\n
    #{post.body}
    """
  end

  defp link(text, url) do
    ~s(<a href="#{escape(url)}">#{escape(text)}</a>)
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
