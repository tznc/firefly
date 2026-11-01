defmodule FirestormWeb.Web.PollComponents do
  @moduledoc """
  Poll UI (see `FirestormWeb.Polls`): the composer's "Add poll" section
  and a post's poll on its thread page.
  """
  use Phoenix.Component

  import FirestormWeb.Web.CoreComponents, only: [icon: 1, input: 1]
  import FirestormWeb.Web.ForumComponents, only: [time_ago: 1]

  alias FirestormWeb.Forums.Poll

  @doc "The composer form's defaults."
  def defaults,
    do: %{"kind" => "single", "results" => "always", "public" => "false", "options_text" => ""}

  @doc """
  The composer's poll errors from a failed post or thread changeset (the
  poll's changeset sits in the post's changes), for the poll form.
  """
  def errors(%Ecto.Changeset{} = changeset) do
    case Ecto.Changeset.get_change(changeset, :posts) do
      [post | _] -> errors(post)
      _no_posts -> poll_errors(Ecto.Changeset.get_change(changeset, :poll))
    end
  end

  defp poll_errors(%Ecto.Changeset{errors: errors}), do: errors
  defp poll_errors(_none), do: []

  @doc """
  The composer's poll section, inside the post form: an "Add poll" button
  (sends `toggle_poll`) or, when `open`, the poll's fields (named
  `poll[...]`) with a "Remove poll" button.
  """
  attr :form, :any, required: true
  attr :open, :boolean, required: true

  def poll_composer(assigns) do
    ~H"""
    <div id="poll-composer">
      <button :if={!@open} type="button" phx-click="toggle_poll" class="btn btn-ghost btn-sm">
        <.icon name="hero-chart-bar" class="size-4" /> Add poll
      </button>
      <fieldset :if={@open} class="space-y-2 rounded-box border border-base-300 p-4">
        <legend class="px-1 font-semibold">Poll</legend>
        <.input
          field={@form[:options_text]}
          type="textarea"
          label={"Options (one per line, 2 to #{Poll.max_options()})"}
          rows="4"
        />
        <div class="grid gap-2 sm:grid-cols-3">
          <.input
            field={@form[:kind]}
            type="select"
            label="Type"
            options={Enum.map(Poll.kinds(), &{Poll.kind_label(&1), &1})}
          />
          <.input field={@form[:min_choices]} type="number" label="At least (multiple)" min="1" />
          <.input field={@form[:max_choices]} type="number" label="At most (multiple)" min="1" />
        </div>
        <div class="grid gap-2 sm:grid-cols-2">
          <.input
            field={@form[:results]}
            type="select"
            label="Show results"
            options={Enum.map(Poll.results_options(), &{Poll.results_label(&1), &1})}
          />
          <.input field={@form[:close_at]} type="datetime-local" label="Close automatically at (optional)" />
        </div>
        <.input field={@form[:public]} type="checkbox" label="Show who voted (public poll)" />
        <button type="button" phx-click="toggle_poll" class="btn btn-ghost btn-xs text-error">
          Remove poll
        </button>
      </fieldset>
    </div>
    """
  end

  @doc """
  A post's poll (`view`, see `FirestormWeb.Polls.view/2`): the vote form
  for those who `can_vote` while it's open (sends `vote` with `poll_id`),
  the results when they may see them, and Close/Reopen for those who
  `can_manage` (sends `close_poll`/`reopen_poll` with `id`).
  """
  attr :view, :map, required: true
  attr :can_vote, :boolean, default: false
  attr :can_manage, :boolean, default: false

  def poll(assigns) do
    assigns = assign(assigns, :poll, assigns.view.poll)

    ~H"""
    <section id={"poll-#{@poll.id}"} class="poll space-y-3 rounded-box border border-base-300 bg-base-200/40 p-4">
      <header class="flex flex-wrap items-center gap-2 text-sm">
        <.icon name="hero-chart-bar" class="size-4" />
        <span class="font-semibold">{Poll.kind_label(@poll.kind)} poll</span>
        <span :if={@poll.kind == "multiple"} class="text-base-content/70">
          (pick {choice_range(@poll)})
        </span>
        <span class="poll-voters text-base-content/70">
          · {voters_text(@view.voters)}
        </span>
        <span :if={@view.closed?} class="poll-closed badge badge-sm">Closed</span>
        <span :if={!@view.closed? && @poll.close_at} class="text-base-content/70">
          · closes <.time_ago id={"poll-#{@poll.id}-close-at"} at={@poll.close_at} />
        </span>
        <span :if={@poll.public} class="text-base-content/70">· public</span>
        <span :if={@can_manage} class="ml-auto">
          <button
            :if={!@view.closed?}
            type="button"
            phx-click="close_poll"
            phx-value-id={@poll.id}
            class="btn btn-ghost btn-xs"
          >
            Close poll
          </button>
          <button
            :if={@view.closed?}
            type="button"
            phx-click="reopen_poll"
            phx-value-id={@poll.id}
            class="btn btn-ghost btn-xs"
          >
            Reopen poll
          </button>
        </span>
      </header>

      <.form
        :if={@can_vote and !@view.closed?}
        for={%{}}
        as={:vote}
        id={"poll-#{@poll.id}-vote"}
        phx-submit="vote"
        class="space-y-2"
      >
        <input type="hidden" name="vote[poll_id]" value={@poll.id} />
        <.choices poll={@poll} mine={@view.mine} />
        <button class="btn btn-primary btn-sm">
          {if @view.mine == [], do: "Vote", else: "Change vote"}
        </button>
      </.form>

      <.results :if={@view.results?} poll={@poll} results={@view.results} voters={@view.voters} />
      <p :if={!@view.results?} class="poll-results-hidden text-sm text-base-content/70">
        {if @poll.results == "voted",
          do: "Results show once you vote.",
          else: "Results show when the poll closes."}
      </p>
    </section>
    """
  end

  defp choice_range(%{min_choices: n, max_choices: n}), do: "#{n}"
  defp choice_range(poll), do: "#{poll.min_choices} to #{poll.max_choices}"

  defp voters_text(1), do: "1 voter"
  defp voters_text(count), do: "#{count} voters"

  attr :poll, :any, required: true
  attr :mine, :list, required: true

  defp choices(%{poll: %{kind: "single"}} = assigns) do
    ~H"""
    <label :for={option <- @poll.options} class="flex items-center gap-2 text-sm">
      <input
        type="radio"
        name="vote[option]"
        value={option.id}
        checked={option.id in @mine}
        class="radio radio-sm"
      />
      {option.text}
    </label>
    """
  end

  defp choices(%{poll: %{kind: "multiple"}} = assigns) do
    ~H"""
    <label :for={option <- @poll.options} class="flex items-center gap-2 text-sm">
      <input
        type="checkbox"
        name="vote[options][]"
        value={option.id}
        checked={option.id in @mine}
        class="checkbox checkbox-sm"
      />
      {option.text}
    </label>
    """
  end

  defp choices(%{poll: %{kind: "ranked"}} = assigns) do
    assigns =
      assign(assigns, :ranks, assigns.mine |> Enum.with_index(1) |> Map.new())

    ~H"""
    <p class="text-xs text-base-content/70">Rank the options you'd accept: 1 is your first choice.</p>
    <label :for={option <- @poll.options} class="flex items-center gap-2 text-sm">
      <select
        name={"vote[ranks][#{option.id}]"}
        class="select select-sm w-20"
        aria-label={"Rank for #{option.text}"}
      >
        <option value="">–</option>
        <option :for={n <- 1..length(@poll.options)} value={n} selected={@ranks[option.id] == n}>
          {n}
        </option>
      </select>
      {option.text}
    </label>
    """
  end

  attr :poll, :any, required: true
  attr :results, :map, required: true
  attr :voters, :integer, required: true

  defp results(assigns) do
    # Shares of voters (a multiple choice voter picks several).
    assigns =
      assign(assigns,
        total: assigns.voters,
        winners: if(assigns.results.runoff, do: assigns.results.runoff.winners, else: [])
      )

    ~H"""
    <div class="poll-results space-y-2">
      <p :if={@poll.kind == "ranked"} class="text-xs text-base-content/70">
        First choices, then instant-runoff rounds below.
      </p>
      <div :for={option <- @poll.options} class="poll-result space-y-1" id={"poll-option-#{option.id}"}>
        <div class="flex justify-between gap-2 text-sm">
          <span>
            {option.text}
            <span :if={option.id in @winners} class="poll-winner badge badge-success badge-xs">
              {if length(@winners) > 1, do: "tied", else: "winner"}
            </span>
          </span>
          <span class="poll-count tabular-nums">
            {Map.get(@results.counts, option.id, 0)} ({percent(Map.get(@results.counts, option.id, 0), @total)}%)
          </span>
        </div>
        <progress
          class="progress progress-primary w-full"
          value={Map.get(@results.counts, option.id, 0)}
          max={max(@total, 1)}
        />
        <p :if={@results.voters_by_option[option.id]} class="poll-option-voters text-xs text-base-content/70">
          {Enum.map_join(@results.voters_by_option[option.id], ", ", &"@#{&1}")}
        </p>
      </div>
      <p :if={@results.voter_names != []} class="poll-option-voters text-xs text-base-content/70">
        Voted: {Enum.map_join(@results.voter_names, ", ", &"@#{&1}")}
      </p>
      <ol :if={@results.runoff && length(@results.runoff.rounds) > 1} class="poll-rounds list-decimal pl-5 text-xs">
        <li :for={round <- @results.runoff.rounds}>
          {Enum.map_join(@poll.options, ", ", &"#{&1.text}: #{Map.get(round.counts, &1.id, "out")}")}
          <span :if={round.eliminated != []}>
            (eliminated: {Enum.map_join(Enum.filter(@poll.options, &(&1.id in round.eliminated)), ", ", & &1.text)})
          </span>
        </li>
      </ol>
    </div>
    """
  end

  defp percent(_count, 0), do: 0
  defp percent(count, total), do: round(count * 100 / total)
end
