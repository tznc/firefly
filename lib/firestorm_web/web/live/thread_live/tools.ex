defmodule FirestormWeb.Web.ThreadLive.Tools do
  @moduledoc """
  A thread's admin tools (the `:moderate_thread` policy): merge it into
  another thread, split replies off (see `FirestormWeb.TopicTools`), set or
  cancel its timer (see `FirestormWeb.TopicTimers`) and its slow mode.
  Other threads are picked by their URL or id.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Forums, Posting, Repo, TopicTimers, TopicTools}
  alias FirestormWeb.Forums.{Post, Thread, ThreadTimer}

  @units %{"minutes" => 60, "hours" => 3600, "days" => 86_400}

  # Slow mode intervals offered, in seconds (0: off).
  @slow_modes [0, 60, 600, 1800, 3600, 4 * 3600, 12 * 3600, 86_400, 7 * 86_400]

  @impl true
  def mount(%{"category_id" => category_id, "id" => id}, _session, socket) do
    user = socket.assigns.current_user
    category = Forums.get_visible_category!(category_id, user)
    thread = Forums.get_visible_thread!(category, id, user)

    cond do
      not can?(user, :moderate_thread) ->
        {:ok, socket |> put_flash(:error, denied_message(user)) |> push_navigate(to: ~p"/")}

      Thread.merged?(thread) ->
        {:ok,
         socket
         |> put_flash(:error, "This thread was merged into another one.")
         |> push_navigate(to: ~p"/")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Thread tools - #{thread.title}")
         |> assign(:category, category)
         |> assign(:categories, Forums.list_categories(user))
         |> assign(:split_form, to_form(%{"category_id" => category.id}, as: :split))
         |> assign(
           :timer_form,
           to_form(%{"action" => "close", "in" => "1", "unit" => "days"}, as: :timer)
         )
         |> load(thread)}
    end
  end

  defp load(socket, thread) do
    thread = Repo.preload(thread, [posts: :user], force: true)

    socket
    |> assign(:thread, thread)
    |> assign(:replies, tl(thread.posts))
    |> assign(:timer, TopicTimers.get_timer(thread))
  end

  defp thread_path(thread), do: ~p"/categories/#{thread.category_id}/threads/#{thread}"

  @impl true
  def handle_event("merge", %{"merge" => %{"target" => target}}, socket) do
    %{thread: thread, current_user: user} = socket.assigns

    with %Thread{} = target <- find_thread(target) || {:error, :no_thread},
         {:ok, target} <- TopicTools.merge(thread, target, user) do
      {:noreply,
       socket
       |> put_flash(:info, "Thread merged into #{target.title}.")
       |> push_navigate(to: thread_path(target))}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, TopicTools.message(reason))}
    end
  end

  def handle_event("split", %{"split" => params}, socket) do
    %{thread: thread, current_user: user} = socket.assigns

    with {:ok, destination} <- split_destination(params),
         {:ok, target} <- TopicTools.split(thread, params["post_ids"] || [], destination, user) do
      {:noreply,
       socket
       |> put_flash(:info, "Posts moved to #{target.title}.")
       |> push_navigate(to: thread_path(target))}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Enum.map(changeset.errors, fn {field, error} -> {field, error} end)

        {:noreply,
         socket
         |> put_flash(:error, "Couldn't create the new thread.")
         |> assign(:split_form, to_form(params, as: :split, errors: errors, action: :validate))}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, TopicTools.message(reason))
         |> assign(:split_form, to_form(params, as: :split))}
    end
  end

  def handle_event("set_timer", %{"timer" => params}, socket) do
    %{thread: thread, current_user: user} = socket.assigns

    with {count, ""} when count > 0 <- Integer.parse(params["in"] || ""),
         {:ok, unit} <- Map.fetch(@units, params["unit"]),
         run_at = DateTime.add(DateTime.utc_now(:second), count * unit),
         {:ok, _timer} <-
           TopicTimers.set_timer(thread, %{action: params["action"], run_at: run_at}, user) do
      {:noreply,
       socket
       |> put_flash(:info, "Timer set.")
       |> assign(:timer_form, to_form(params, as: :timer))
       |> load(thread)}
    else
      _invalid ->
        {:noreply,
         socket
         |> put_flash(:error, "Pick an action and a time in the future.")
         |> assign(:timer_form, to_form(params, as: :timer))}
    end
  end

  def handle_event("cancel_timer", _params, socket) do
    :ok = TopicTimers.cancel_timer(socket.assigns.thread, socket.assigns.current_user)
    {:noreply, socket |> put_flash(:info, "Timer cancelled.") |> load(socket.assigns.thread)}
  end

  def handle_event("slow_mode", %{"slow_mode" => %{"seconds" => seconds}}, socket) do
    with {seconds, ""} when seconds in @slow_modes <- Integer.parse(seconds),
         {:ok, thread} <-
           TopicTools.set_slow_mode(socket.assigns.thread, seconds, socket.assigns.current_user) do
      message =
        if thread.slow_mode_seconds, do: "Slow mode is on.", else: "Slow mode is off."

      {:noreply, socket |> put_flash(:info, message) |> load(thread)}
    else
      _invalid -> {:noreply, put_flash(socket, :error, "Pick one of the intervals.")}
    end
  end

  defp split_destination(%{"target" => target} = params) do
    cond do
      String.trim(target || "") == "" -> {:ok, {:new, params}}
      thread = find_thread(target) -> {:ok, {:existing, thread}}
      true -> {:error, :no_thread}
    end
  end

  defp split_destination(params), do: {:ok, {:new, params}}

  # A thread from its URL (".../threads/42", any suffix) or id.
  defp find_thread(input) do
    case Regex.run(~r{(?:threads/|^\s*)(\d+)}, input || "") do
      [_, id] -> Forums.get_thread(String.to_integer(id))
      nil -> nil
    end
  end

  defp slow_mode_label(0), do: "Off"
  defp slow_mode_label(seconds), do: "One reply every #{Posting.duration_text(seconds)}"

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:slow_modes, Enum.map(@slow_modes, &{slow_mode_label(&1), &1}))
      |> assign(:actions, Enum.map(ThreadTimer.actions(), &{String.capitalize(&1), &1}))

    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Thread tools">
        <:subtitle>
          <.link navigate={thread_path(@thread)} class="link">{@thread.title}</.link>
          · Every change is recorded in the staff log.
        </:subtitle>
      </.page_header>

      <section id="merge" class="card border border-base-300 bg-base-100">
        <div class="card-body space-y-2">
          <h2 class="card-title">Merge into another thread</h2>
          <p class="text-sm text-base-content/70">
            Every post moves into that thread, in posting order. This thread stays behind,
            closed, and its links lead there.
          </p>
          <.form for={%{}} as={:merge} id="merge-form" phx-submit="merge" class="flex items-end gap-2">
            <div class="flex-1">
              <.input id="merge-target" name="merge[target]" value="" label="Thread URL or id" />
            </div>
            <.button data-confirm="Merge every post of this thread into the other one?">
              Merge
            </.button>
          </.form>
        </div>
      </section>

      <section id="split" class="card border border-base-300 bg-base-100">
        <div class="card-body space-y-2">
          <h2 class="card-title">Split replies off</h2>
          <p :if={@replies == []} class="text-sm text-base-content/70">
            This thread has no replies to split off.
          </p>
          <.form :if={@replies != []} for={@split_form} id="split-form" phx-submit="split" class="space-y-3">
            <fieldset class="max-h-96 space-y-1 overflow-y-auto">
              <legend class="mb-1 font-medium">Replies to move</legend>
              <label :for={post <- @replies} class="flex items-start gap-2 text-sm" for={"split-post-#{post.id}"}>
                <input
                  type="checkbox"
                  id={"split-post-#{post.id}"}
                  name="split[post_ids][]"
                  value={post.id}
                  checked={to_string(post.id) in List.wrap(@split_form.params["post_ids"])}
                  class="checkbox checkbox-sm"
                />
                <span>
                  <span class="font-medium">@{post.user.username}</span>
                  <span :if={Post.deleted?(post)} class="badge badge-ghost badge-sm">deleted</span>
                  {String.slice(post.body, 0, 120)}
                </span>
              </label>
            </fieldset>
            <div class="grid gap-2 sm:grid-cols-2">
              <.input field={@split_form[:title]} label="New thread title" />
              <.input
                field={@split_form[:category_id]}
                type="select"
                label="New thread category"
                options={Enum.map(@categories, &{&1.title, &1.id})}
              />
            </div>
            <.input field={@split_form[:target]} label="Or move them into an existing thread (URL or id)" />
            <div class="flex justify-end">
              <.button>Move posts</.button>
            </div>
          </.form>
        </div>
      </section>

      <section id="timer" class="card border border-base-300 bg-base-100">
        <div class="card-body space-y-2">
          <h2 class="card-title">Timer</h2>
          <div :if={@timer} id="current-timer" class="flex items-center gap-2">
            <span>
              {ThreadTimer.label(@timer)} <.time_ago id="current-timer-at" at={@timer.run_at} />.
            </span>
            <button phx-click="cancel_timer" class="btn btn-ghost btn-sm">Cancel timer</button>
          </div>
          <.form for={@timer_form} id="timer-form" phx-submit="set_timer" class="flex flex-wrap items-end gap-2">
            <.input field={@timer_form[:action]} type="select" label="Action" options={@actions} />
            <.input field={@timer_form[:in]} type="number" min="1" label="In" />
            <.input
              field={@timer_form[:unit]}
              type="select"
              label="Unit"
              options={[{"minutes", "minutes"}, {"hours", "hours"}, {"days", "days"}]}
            />
            <.button>{if @timer, do: "Replace timer", else: "Set timer"}</.button>
          </.form>
        </div>
      </section>

      <section id="slow-mode" class="card border border-base-300 bg-base-100">
        <div class="card-body space-y-2">
          <h2 class="card-title">Slow mode</h2>
          <p class="text-sm text-base-content/70">
            How often each member may reply. Admins are exempt.
          </p>
          <.form for={%{}} as={:slow_mode} id="slow-mode-form" phx-submit="slow_mode" class="flex items-end gap-2">
            <.input
              id="slow-mode-seconds"
              name="slow_mode[seconds]"
              type="select"
              label="Interval"
              value={@thread.slow_mode_seconds || 0}
              options={@slow_modes}
            />
            <.button>Save</.button>
          </.form>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
