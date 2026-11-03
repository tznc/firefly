defmodule FireflyWeb.StaffLive.WatchedWords do
  @moduledoc """
  Watched words (admins only; see `Firefly.Moderation.WatchedWords`): one
  tab per action, each listing its words with a form to add one, and a box
  to test which words some text matches.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.Repo
  alias Firefly.Moderation.{WatchedWord, WatchedWords}

  @labels %{
    "block" => "Block",
    "censor" => "Censor",
    "require_approval" => "Require approval",
    "flag" => "Flag",
    "replace" => "Replace",
    "tag" => "Tag",
    "silence" => "Silence",
    "link" => "Link"
  }

  @help %{
    "block" =>
      "Posts, titles and messages with these words can't be saved; the author is told which word.",
    "censor" => "These words are shown masked, like ■■■■.",
    "require_approval" => "Posts with these words wait in the review queue for staff approval.",
    "flag" => "Posts with these words are published and flagged for staff review.",
    "replace" => "These words are shown as their replacement text.",
    "tag" => "New threads with these words get the tags given.",
    "silence" => "Members writing these words are silenced, and the post waits for approval.",
    "link" => "These words are shown as links to the URL given."
  }

  @replacement_labels %{
    "replace" => "Replace with",
    "tag" => "Tags (comma-separated)",
    "link" => "Link to (URL)"
  }

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_watched_words) do
      {:ok,
       socket
       |> assign(:page_title, "Watched words")
       |> assign(:labels, @labels)
       |> assign(:test, %{text: "", matches: []})}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    action = if params["action"] in WatchedWord.actions(), do: params["action"], else: "block"

    {:noreply,
     socket
     |> assign(:action, action)
     |> assign(:help, @help[action])
     |> assign(:replacement_label, @replacement_labels[action])
     |> assign(:form, to_form(WatchedWords.change_word(%{"action" => action})))
     |> assign(:test, test(socket.assigns.test.text, action))
     |> load()}
  end

  defp load(socket) do
    socket
    |> assign(:words, WatchedWords.list(socket.assigns.action))
    |> assign(:counts, WatchedWords.counts())
  end

  @impl true
  def handle_event("validate", %{"watched_word" => params}, socket) do
    changeset = WatchedWords.change_word(with_action(params, socket))
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"watched_word" => params}, socket) do
    case WatchedWords.create(socket.assigns.current_user, with_action(params, socket)) do
      {:ok, word} ->
        {:noreply,
         socket
         |> put_flash(:info, "Now watching \"#{word.word}\".")
         |> assign(:form, to_form(WatchedWords.change_word(%{"action" => word.action})))
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case Repo.get(WatchedWord, id) do
      nil ->
        {:noreply, load(socket)}

      word ->
        :ok = WatchedWords.delete(word, socket.assigns.current_user)

        {:noreply,
         socket
         |> put_flash(:info, "Stopped watching \"#{word.word}\".")
         |> load()}
    end
  end

  def handle_event("test", %{"text" => text}, socket) do
    {:noreply, assign(socket, :test, test(text, socket.assigns.action))}
  end

  defp test(text, action), do: %{text: text, matches: WatchedWords.match(text, action)}

  defp with_action(params, socket), do: Map.put(params, "action", socket.assigns.action)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} staff>
      <.page_header title="Watched words" navigate={~p"/staff/watched-words"}>
        <:subtitle>
          Words to watch for in titles, posts and messages: case-insensitive whole words, <code>*</code>
          matches any characters.
        </:subtitle>
      </.page_header>

      <div role="tablist" class="tabs tabs-border flex-wrap" id="watched-word-actions">
        <.link
          :for={action <- WatchedWord.actions()}
          patch={~p"/staff/watched-words?#{[action: action]}"}
          role="tab"
          id={"tab-#{action}"}
          class={["tab", action == @action && "tab-active"]}
        >
          {@labels[action]}
          <span :if={@counts[action]} class="badge badge-sm ml-1">{@counts[action]}</span>
        </.link>
      </div>

      <p class="text-sm text-base-content/70" id="action-help">{@help}</p>

      <.form
        for={@form}
        id="watched-word-form"
        phx-change="validate"
        phx-submit="save"
        class="card border border-base-300 bg-base-100"
      >
        <div class="card-body gap-2">
          <h2 class="card-title">Add a word</h2>
          <.input field={@form[:word]} type="text" label="Word" placeholder="spam*" />
          <.input field={@form[:regex]} type="checkbox" label="Regular expression" />
          <.input
            :if={@replacement_label}
            field={@form[:replacement]}
            type="text"
            label={@replacement_label}
          />
          <div class="flex justify-end">
            <.button variant="primary" phx-disable-with="Adding...">Add word</.button>
          </div>
        </div>
      </.form>

      <p :if={@words == []} id="words-empty" class="text-base-content/70">No words yet.</p>

      <ul :if={@words != []} id="watched-words" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
        <li :for={word <- @words} id={"word-#{word.id}"} class="flex items-center gap-3 p-3">
          <code class="flex-1 break-all">{word.word}</code>
          <span :if={word.regex} class="badge badge-sm badge-ghost">regex</span>
          <span :if={word.replacement} class="text-sm text-base-content/70 break-all">→ {word.replacement}</span>
          <button
            type="button"
            class="btn btn-ghost btn-xs text-error"
            phx-click="delete"
            phx-value-id={word.id}
            data-confirm={"Stop watching \"#{word.word}\"?"}
            aria-label={"Remove #{word.word}"}
          >
            Remove
          </button>
        </li>
      </ul>

      <form id="watched-word-test" phx-change="test" phx-submit="test" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-2">
          <h2 class="card-title">Test</h2>
          <textarea
            name="text"
            class="textarea w-full"
            rows="2"
            aria-label="Text to test"
            placeholder="Some text to check against these words"
            phx-debounce="300"
          >{@test.text}</textarea>
          <p id="test-result" class="text-sm">
            <%= if @test.matches == [] do %>
              No matches.
            <% else %>
              Matches: {Enum.join(@test.matches, ", ")}
            <% end %>
          </p>
        </div>
      </form>
    </Layouts.app>
    """
  end
end
