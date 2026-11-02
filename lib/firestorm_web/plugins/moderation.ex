defmodule FirestormWeb.Plugins.Moderation do
  @moduledoc """
  Plugins' moderation hooks.

  `moderate_post` runs synchronously when a new thread, reply or edit is
  saved, whichever way it comes (web, API, inbound email: they all go
  through `FirestormWeb.Forums`), as a changeset validation next to
  `FirestormWeb.Forums.SpamGuard`. Each active plugin implementing it, in
  hook order, answers:

    * `allow`;
    * `queue` with a reason: the post waits in the review queue (the same
      one new users' posts wait in) with "Plugin <name>: <reason>" shown to
      staff;
    * `reject` with a message: the post isn't saved and the author sees the
      message, like any validation error. The first rejection wins.

  The time limit is strict (`config :firestorm_web,
  FirestormWeb.Plugins.Moderation, timeout:`, 300 ms by default). When a
  plugin fails or times out, staff choose per plugin what happens: by
  default posting goes ahead (fail open); with fail closed the post is
  refused with a "try again" message. Admins' posts aren't checked, nor are
  posts in categories anonymous visitors can't read (plugins never see
  private content).

  `flag_created` runs when a member flags a public post; a plugin answering
  `hide` hides the post until staff review it, as enough flags would.
  """

  import Ecto.Changeset

  alias FirestormWeb.{Forums, Plugin, Plugins}
  alias FirestormWeb.Forums.{Category, Thread, User}
  alias FirestormWeb.Plugin.Runner
  alias FirestormWeb.Plugins.Events

  @doc """
  Runs the moderation hooks on a post changeset. `context`: `kind`
  (`"thread"`, `"post"` or `"edit"`) and either `thread` (the post's
  thread, or a function loading it, only called if a plugin moderates) or,
  for a new thread, `category` and `title`.
  """
  def validate(%Ecto.Changeset{valid?: false} = changeset, _user, _context), do: changeset

  def validate(%Ecto.Changeset{} = changeset, %User{} = user, context) do
    plugins = Plugins.implementing("moderate_post")

    if plugins == [] or Forums.admin?(user) do
      changeset
    else
      context = Map.update(context, :thread, nil, &if(is_function(&1, 0), do: &1.(), else: &1))

      if public?(context),
        do: apply_decision(changeset, decide(plugins, input(changeset, user, context))),
        else: changeset
    end
  end

  @doc "`validate/3` for a new thread's changeset (with its first post nested)."
  def validate_thread(%Ecto.Changeset{} = changeset, %User{} = user, %Category{} = category) do
    case get_change(changeset, :posts) do
      [post] ->
        context = %{
          kind: "thread",
          thread: nil,
          category: category,
          title: get_field(changeset, :title)
        }

        checked = validate(post, user, context)
        changeset = put_assoc(changeset, :posts, [checked])
        if checked.valid?, do: changeset, else: %{changeset | valid?: false}

      _ ->
        changeset
    end
  end

  defp public?(%{thread: %Thread{} = thread}),
    do: Bodyguard.permit?(Forums, :view_thread, nil, thread)

  defp public?(%{category: %Category{} = category}),
    do: Bodyguard.permit?(Forums, :view_category, nil, category)

  defp input(changeset, user, context) do
    %{
      "kind" => context.kind,
      "title" => if(context.thread, do: context.thread.title, else: context[:title]),
      "body" => get_field(changeset, :body),
      "user" => %{"id" => user.id, "username" => user.username, "created_at" => user.inserted_at},
      "thread" => context.thread && Events.thread_data(context.thread),
      "category_id" =>
        if(context.thread, do: context.thread.category_id, else: context.category.id)
    }
  end

  defp decide(plugins, input) do
    timeout = Application.get_env(:firestorm_web, __MODULE__, [])[:timeout] || 300

    Enum.reduce_while(plugins, :allow, fn plugin, decision ->
      case verdict(Runner.invoke(plugin, "moderate_post", [input], timeout: timeout), plugin) do
        :allow -> {:cont, decision}
        {:queue, _reason} = queue when decision == :allow -> {:cont, queue}
        {:queue, _reason} -> {:cont, decision}
        {:reject, _message} = reject -> {:halt, reject}
      end
    end)
  end

  defp verdict({:ok, %{"action" => "allow"}}, _plugin), do: :allow

  defp verdict({:ok, %{"action" => "queue"} = answer}, plugin),
    do:
      {:queue, "Plugin #{plugin.manifest.name}: #{text(answer["reason"], "flagged for review")}"}

  defp verdict({:ok, %{"action" => "reject"} = answer}, _plugin),
    do: {:reject, text(answer["message"], "This post was refused.")}

  defp verdict(_failed, %Plugin{fail_closed: true}),
    do: {:reject, "Your post couldn't be checked right now. Please try again in a moment."}

  defp verdict(_failed, _plugin), do: :allow

  defp text(value, _default) when is_binary(value) and value != "",
    do: String.slice(value, 0, 500)

  defp text(_value, default), do: default

  defp apply_decision(changeset, :allow), do: changeset

  defp apply_decision(changeset, {:queue, reason}) do
    changeset
    |> put_change(:queued_at, DateTime.utc_now(:second))
    |> put_change(:queued_reason, reason)
  end

  defp apply_decision(changeset, {:reject, message}),
    do: add_error(changeset, :body, message, validation: :plugin)

  @doc """
  Runs the `flag_created` hooks for a flag on `post` (public posts only).
  Returns `:hide` if a plugin asked to hide the post, else `:none`.
  """
  def flag_created(post, thread, flag) do
    plugins = Plugins.implementing("flag_created")

    if plugins == [] or not Bodyguard.permit?(Forums, :view_thread, nil, thread) do
      :none
    else
      input = %{
        "post" => Events.post_data(post, thread),
        "thread" => Events.thread_data(thread),
        "flag" => %{"reason" => flag.reason, "note" => flag.note}
      }

      timeout = Application.get_env(:firestorm_web, __MODULE__, [])[:timeout] || 300

      if Enum.any?(
           plugins,
           &match?(
             {:ok, %{"action" => "hide"}},
             Runner.invoke(&1, "flag_created", [input], timeout: timeout)
           )
         ),
         do: :hide,
         else: :none
    end
  end
end
