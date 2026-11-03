defmodule FireflyWeb.ChatComponents do
  @moduledoc """
  The pieces of the chat page (see `FireflyWeb.ChatLive`): a message with
  its actions, reactions and thread link, and the composer.
  """
  use FireflyWeb, :html

  alias Firefly.Chat
  alias Firefly.Chat.Message
  alias Firefly.Rendering.Emoji

  @quick_reactions ~w(👍 ❤️ 😂 🎉 👀 🙏)

  @doc "The reactions offered in a message's menu."
  def quick_reactions, do: @quick_reactions

  @doc """
  A chat message. `perms` are the viewer's channel-wide permissions
  (`admin?`, `post?`, `pin?`); what's theirs alone is decided here, and
  the server checks again.
  """
  attr :message, Message, required: true
  attr :user, :any, required: true
  attr :perms, :map, required: true
  attr :editing, :boolean, default: false
  attr :unread_divider, :boolean, default: false
  attr :thread_unread, :integer, default: 0
  attr :in_thread, :boolean, default: false
  attr :thread_path, :string, default: nil, doc: "the message's thread pane"

  def message(assigns) do
    assigns
    |> assign(permissions(assigns.message, assigns.user, assigns.perms))
    |> assign(:reactions, Chat.reaction_groups(assigns.message))
    |> render_message()
  end

  # What the viewer may do to this message.
  defp permissions(message, user, perms) do
    own? = message.user_id == user.id
    live? = not Message.deleted?(message)

    [
      own?: own?,
      deleted?: not live?,
      hidden?: hidden?(message, own?, perms),
      can_edit?: own? and live? and perms.post?,
      can_delete?: live? and (own? or perms.admin?),
      can_restore?: restorable?(message, user, perms),
      can_react?: live? and perms.post?,
      can_pin?: live? and perms.pin?,
      can_flag?: live? and not own?
    ]
  end

  # A deleted message shows as such, except to its author and staff.
  defp hidden?(%Message{deleted_at: nil}, _own?, _perms), do: false
  defp hidden?(_message, own?, perms), do: not (own? or perms.admin?)

  defp restorable?(%Message{deleted_at: nil}, _user, _perms), do: false
  defp restorable?(_message, _user, %{admin?: true}), do: true

  defp restorable?(message, user, _perms),
    do: message.deleted_by_id == user.id and message.user_id == user.id

  defp render_message(assigns) do
    ~H"""
    <div
      :if={@unread_divider}
      id="new-messages-divider"
      class="divider divider-primary my-1 text-xs text-primary"
    >
      New messages
    </div>
    <article
      id={"#{if @in_thread, do: "thread", else: "chat"}-message-#{@message.id}"}
      class={[
        "group relative flex gap-3 rounded-box px-2 py-1.5 hover:bg-base-200",
        @message.pinned_at && "bg-warning/10"
      ]}
    >
      <.avatar :if={@message.user} user={@message.user} size="size-8" />
      <div class="min-w-0 flex-1">
        <header class="flex flex-wrap items-baseline gap-x-2 text-sm">
          <span :if={@message.user} class="font-semibold">{@message.user.username}</span>
          <span :if={!@message.user} class="font-semibold italic opacity-60">deleted user</span>
          <span class="text-xs text-base-content/60">
            <.time_ago id={"chat-message-#{@message.id}-#{@in_thread}-time"} at={@message.inserted_at} />
          </span>
          <span :if={@message.edited_at && !@hidden?} class="text-xs text-base-content/60">
            (edited)
          </span>
          <span :if={@message.pinned_at} class="badge badge-warning badge-xs gap-1">
            <.icon name="hero-bookmark-micro" class="size-3" /> pinned
          </span>
        </header>
        <blockquote
          :if={@message.in_reply_to && !@hidden?}
          class="my-1 border-l-2 border-base-300 pl-2 text-xs text-base-content/70"
        >
          <span :if={@message.in_reply_to.user} class="font-semibold">
            @{@message.in_reply_to.user.username}:
          </span>
          {excerpt(@message.in_reply_to)}
        </blockquote>
        <p :if={@hidden?} class="text-sm italic text-base-content/60">This message was deleted.</p>
        <.form
          :if={@editing && !@hidden?}
          for={%{"body" => @message.body}}
          as={:edit}
          id={"chat-edit-#{@message.id}-#{@in_thread}"}
          phx-submit="save_edit"
          class="space-y-2"
        >
          <input type="hidden" name="message_id" value={@message.id} />
          <textarea name="edit[body]" rows="3" class="textarea w-full text-sm" aria-label="Edit message">{@message.body}</textarea>
          <div class="flex gap-2">
            <button class="btn btn-primary btn-xs">Save</button>
            <button type="button" class="btn btn-ghost btn-xs" phx-click="cancel_edit">
              Cancel
            </button>
          </div>
        </.form>
        <div :if={!@hidden? && !@editing} class={@deleted? && "opacity-50"}>
          <span :if={@deleted?} class="badge badge-error badge-xs">deleted</span>
          <.markdown id={"chat-message-#{@message.id}-#{@in_thread}-body"} body={@message.body} viewer={@user} />
        </div>
        <div :if={@reactions != [] && !@hidden?} class="mt-1 flex flex-wrap gap-1">
          <button
            :for={reaction <- @reactions}
            type="button"
            phx-click="react"
            phx-value-id={@message.id}
            phx-value-emoji={reaction.emoji}
            disabled={!@can_react?}
            title={Enum.map_join(reaction.users, ", ", &"@#{&1}")}
            aria-label={"#{reaction.emoji} #{length(reaction.users)}"}
            class={[
              "btn btn-xs gap-1",
              @user.username in reaction.users && "btn-primary btn-soft",
              @user.username not in reaction.users && "btn-ghost border-base-300"
            ]}
          >
            <.reaction_emoji emoji={reaction.emoji} /> {length(reaction.users)}
          </button>
        </div>
        <.link
          :if={!@in_thread && @message.reply_count > 0 && @thread_path}
          patch={@thread_path}
          class="link link-primary mt-1 inline-flex items-center gap-1 text-xs"
        >
          <.icon name="hero-chat-bubble-left-right-micro" class="size-3" />
          {replies(@message.reply_count)}
          <span :if={@thread_unread > 0} class="badge badge-primary badge-xs">
            {@thread_unread} new
          </span>
        </.link>
      </div>
      <div class="dropdown dropdown-end absolute top-0 right-1 opacity-0 group-hover:opacity-100 focus-within:opacity-100">
        <button
          type="button"
          tabindex="0"
          class="btn btn-ghost btn-xs btn-square"
          aria-label={"Actions for message #{@message.id}"}
        >
          <.icon name="hero-ellipsis-horizontal" class="size-4" />
        </button>
        <ul
          tabindex="0"
          class="dropdown-content menu menu-sm z-20 w-52 rounded-box border border-base-300 bg-base-100 p-1 shadow"
        >
          <li :if={@can_react?} class="flex-row flex-wrap">
            <button
              :for={emoji <- quick_reactions()}
              type="button"
              class="px-1 text-lg"
              phx-click="react"
              phx-value-id={@message.id}
              phx-value-emoji={emoji}
              aria-label={"React #{emoji}"}
            >
              {emoji}
            </button>
            <button
              type="button"
              class="px-1"
              phx-click={JS.dispatch("chat:react", to: "#reaction-picker", detail: %{id: @message.id})}
              aria-label="More reactions"
            >
              <.icon name="hero-face-smile" class="size-4" />
            </button>
          </li>
          <li :if={@perms.post? && !@deleted? && !@in_thread}>
            <button type="button" phx-click="reply" phx-value-id={@message.id}>
              <.icon name="hero-arrow-uturn-left" class="size-4" /> Quote reply
            </button>
          </li>
          <li :if={!@in_thread && !@deleted? && @thread_path}>
            <.link patch={@thread_path}>
              <.icon name="hero-chat-bubble-left-right" class="size-4" /> Reply in thread
            </.link>
          </li>
          <li :if={@can_edit?}>
            <button type="button" phx-click="edit" phx-value-id={@message.id}>
              <.icon name="hero-pencil" class="size-4" /> Edit
            </button>
          </li>
          <li :if={@message.edited_at && !@hidden?}>
            <button type="button" phx-click="history" phx-value-id={@message.id}>
              <.icon name="hero-clock" class="size-4" /> Edit history
            </button>
          </li>
          <li :if={@can_pin?}>
            <button
              type="button"
              phx-click={if @message.pinned_at, do: "unpin", else: "pin"}
              phx-value-id={@message.id}
            >
              <.icon name="hero-bookmark" class="size-4" />
              {if @message.pinned_at, do: "Unpin", else: "Pin"}
            </button>
          </li>
          <li :if={@can_flag?}>
            <button type="button" phx-click="flag_form" phx-value-id={@message.id}>
              <.icon name="hero-flag" class="size-4" /> Flag
            </button>
          </li>
          <li :if={@can_delete?}>
            <button
              type="button"
              phx-click="delete"
              phx-value-id={@message.id}
              data-confirm="Delete this message?"
              class="text-error"
            >
              <.icon name="hero-trash" class="size-4" /> Delete
            </button>
          </li>
          <li :if={@can_restore?}>
            <button type="button" phx-click="restore" phx-value-id={@message.id}>
              <.icon name="hero-arrow-uturn-up" class="size-4" /> Restore
            </button>
          </li>
        </ul>
      </div>
    </article>
    """
  end

  defp replies(1), do: "1 reply"
  defp replies(count), do: "#{count} replies"

  @doc "The start of a message, as plain text."
  def excerpt(%Message{deleted_at: nil, body: body}) do
    text = String.replace(body, ~r/\s+/, " ")
    if String.length(text) > 120, do: String.slice(text, 0, 120) <> "…", else: text
  end

  def excerpt(%Message{}), do: "(deleted)"

  @doc "A reaction's emoji: the character, or a custom emoji's image."
  attr :emoji, :string, required: true

  def reaction_emoji(assigns) do
    assigns = assign(assigns, :url, custom_url(assigns.emoji))

    ~H"""
    <img :if={@url} src={@url} alt={@emoji} class="emoji size-4" />
    <span :if={!@url}>{@emoji}</span>
    """
  end

  defp custom_url(":" <> rest), do: Map.get(Emoji.custom(), String.trim_trailing(rest, ":"))
  defp custom_url(_emoji), do: nil

  @doc """
  The composer: Enter sends, Shift+Enter starts a new line, `@` and `:`
  autocomplete, an emoji picker and (with `uploads`) attachments picked,
  dropped or pasted.
  """
  attr :form, Phoenix.HTML.Form, required: true
  attr :id, :string, required: true
  attr :submit, :string, required: true
  attr :uploads, :map, default: nil
  attr :thread_id, :any, default: nil, doc: "the thread written in, for the typing indicator"
  attr :placeholder, :string, required: true
  slot :header

  def composer(assigns) do
    assigns = assign(assigns, :custom_emoji, custom_emoji_json())

    ~H"""
    <.form for={@form} id={@id} phx-submit={@submit} phx-change="draft" class="border-t border-base-300 p-3">
      {render_slot(@header)}
      <div
        id={"#{@id}-dropzone"}
        class="relative rounded-box"
        phx-drop-target={@uploads && @uploads.attachment.ref}
        phx-hook={@uploads && "PasteUpload"}
        data-upload="attachment"
      >
        <textarea
          id={"#{@id}-body"}
          name={@form[:body].name}
          rows="2"
          phx-hook="ChatComposer"
          phx-debounce="300"
          data-menu={"#{@id}-mentions"}
          data-custom-emoji={@custom_emoji}
          data-thread={@thread_id}
          placeholder={@placeholder}
          aria-label="Message"
          class="textarea w-full resize-none text-sm"
        >{Phoenix.HTML.Form.normalize_value("textarea", @form[:body].value)}</textarea>
        <ul
          id={"#{@id}-mentions"}
          phx-update="ignore"
          role="listbox"
          aria-label="Suggestions"
          class="menu absolute bottom-full left-0 z-20 hidden w-64 rounded-box border border-base-300 bg-base-100 p-1 shadow"
        >
        </ul>
      </div>
      <p :for={error <- @form[:body].errors} class="mt-1 text-sm text-error">
        {translate_error(error)}
      </p>
      <div class="mt-2 flex flex-wrap items-center gap-2">
        <div
          id={"#{@id}-emoji"}
          class="relative"
          phx-hook="EmojiPicker"
          phx-update="ignore"
          data-target={"#{@id}-body"}
          data-custom-emoji={@custom_emoji}
        >
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            data-toggle
            aria-haspopup="true"
            aria-expanded="false"
            aria-label="Emoji"
          >
            <.icon name="hero-face-smile" class="size-4" />
          </button>
          <.emoji_panel />
        </div>
        <%= if @uploads do %>
          <label class="btn btn-ghost btn-sm btn-square" for={@uploads.attachment.ref} title="Attach files">
            <.icon name="hero-paper-clip" class="size-4" />
          </label>
          <.live_file_input upload={@uploads.attachment} class="hidden" aria-label="add-attachment" />
          <progress
            :for={entry <- @uploads.attachment.entries}
            class="progress progress-primary w-20"
            value={entry.progress}
            max="100"
          />
        <% end %>
        <span class="text-xs text-base-content/50">Enter to send, Shift+Enter for a new line</span>
        <button class="btn btn-primary btn-sm ml-auto" phx-disable-with="Sending...">
          <.icon name="hero-paper-airplane" class="size-4" /> Send
        </button>
      </div>
    </.form>
    """
  end

  @doc "The emoji picker's searchable panel (see the `EmojiPicker` hook)."
  attr :class, :string, default: "absolute bottom-full left-0 z-30 mb-1"

  def emoji_panel(assigns) do
    ~H"""
    <div
      data-panel
      hidden
      role="dialog"
      aria-label="Emoji"
      class={["w-80 rounded-box border border-base-300 bg-base-100 p-2 shadow", @class]}
    >
      <input type="search" class="input input-sm mb-2 w-full" placeholder="Search emoji" aria-label="Search emoji" />
      <div data-grid class="grid max-h-64 grid-cols-8 overflow-y-auto"></div>
    </div>
    """
  end

  @doc "The site's custom emoji, as JSON for the pickers."
  def custom_emoji_json do
    Jason.encode!(for {name, url} <- Emoji.custom(), do: %{name: name, url: url})
  end
end
