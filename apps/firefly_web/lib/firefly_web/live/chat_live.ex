defmodule FireflyWeb.ChatLive do
  @moduledoc """
  The chat page (`/chat`, see `Firefly.Chat`): the sidebar of the member's
  channels and direct messages with unread and mention counts, and one of

    * `:index` - the channels to browse and follow (staff also create them)
    * `:new_dm` - starting a direct message
    * `:channel` - a channel's messages, newest at the bottom, older ones
      loaded on scrolling up, with a "new messages" divider at the first
      unread one, who's here and who's typing, and the composer;
      `?message=<id>` opens it around that message (from search)
    * `:thread` - the same, with the thread of a message (by its id) open
      beside it

  and a side pane: the thread, the channel's threads, its pinned messages,
  search, a message's edit history, or the channel's settings (following,
  muting and notification level; members; for staff, editing the channel
  and its status).

  Everything is live: messages, edits, reactions and pins arrive over the
  channel's PubSub topic (inserted into LiveView streams), presence is
  `FireflyWeb.Presence`, and the sidebar follows every channel in it.
  Reading a channel marks it read.
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{AI, Chat, Discussion, RateLimit}
  alias Firefly.AI.{Summaries, Translations}
  alias Firefly.Chat.Channel
  alias Firefly.Moderation.{Flag, Posting}
  alias FireflyWeb.{ChatComponents, Editor, Presence}

  @typing_seconds 4

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    if Chat.can?(user, :use_chat) do
      if connected?(socket) do
        Chat.subscribe_user(user)
        Chat.subscribe_channels()
      end

      {:ok,
       socket
       |> assign(
         page_title: "Chat",
         channel: nil,
         subscribed: MapSet.new(),
         pane: nil,
         thread_original: nil,
         reply_to: nil,
         editing: nil,
         typing: %{},
         present: [],
         focus: nil,
         history: nil,
         search: nil,
         search_results: [],
         ai: nil,
         language: viewer_language(socket),
         admin?: Firefly.Accounts.admin?(user),
         can_dm?: Chat.can?(user, :create_direct_message)
       )
       |> stream(:messages, [])
       |> stream(:thread_messages, [])
       |> assign_form(:form, "")
       |> assign_form(:thread_form, "")
       |> assign(:dm_form, to_form(%{"usernames" => ""}, as: :dm))
       |> assign(:channel_form, to_form(Chat.change_channel()))
       |> load_sidebar()
       |> Editor.allow_attachments(&handle_progress/3)
       |> Editor.mention_search()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Chat isn't available to you.")
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    socket = assign(socket, focus: nil)

    case socket.assigns.live_action do
      :index ->
        {:noreply, socket |> leave_channel() |> assign(page_title: "Chat") |> load_browse()}

      :new_dm ->
        {:noreply, socket |> leave_channel() |> assign(page_title: "New message")}

      :channel ->
        {:noreply, socket |> open_channel(params) |> close_thread()}

      :thread ->
        {:noreply, socket |> open_channel(params) |> open_thread(params["message_id"])}
    end
  end

  ## Opening channels and threads

  defp open_channel(socket, %{"id" => id} = params) do
    user = socket.assigns.current_user
    channel = Chat.get_channel(id)
    current = socket.assigns.channel

    cond do
      is_nil(channel) or not Chat.can?(user, :view_channel, channel) ->
        socket |> put_flash(:error, "Channel not found.") |> push_patch(to: ~p"/chat")

      current && current.id == channel.id && is_nil(params["message"]) &&
          not socket.assigns[:has_newer] ->
        socket

      true ->
        socket
        |> leave_channel()
        |> enter_channel(channel, parse_id(params["message"]))
    end
  end

  defp enter_channel(socket, channel, around) do
    user = socket.assigns.current_user
    membership = Chat.membership(channel, user)
    last_read = membership && membership.last_read_message_id

    socket = socket |> track(channel) |> subscribe(channel)
    messages = initial_messages(channel, user, around, socket)

    # Followers only; never having read counts as having read nothing.
    first_unread =
      membership &&
        Enum.find_value(messages, &(&1.id > (last_read || 0) and &1.user_id != user.id and &1.id))

    if connected?(socket) and membership, do: Chat.mark_read(channel, user)

    socket
    |> assign(
      channel: channel,
      page_title: Chat.title(channel, user),
      membership: membership,
      perms: perms(channel, user, socket.assigns.admin?),
      first_unread: first_unread,
      has_more: messages != [],
      has_newer: around != nil and newer?(channel, user, messages),
      oldest_id: oldest_id(messages),
      thread_unread: Chat.thread_unread_counts(channel, user),
      reply_to: nil,
      editing: nil,
      typing: %{},
      present: present(channel),
      focus: focus(around, first_unread)
    )
    |> assign_form(:form, "")
    |> stream(:messages, messages, reset: true)
    |> push_event("chat_opened", %{focus: focus(around, first_unread)})
  end

  defp track(socket, channel) do
    if connected?(socket) do
      user = socket.assigns.current_user
      topic = Chat.presence_topic(channel)
      Phoenix.PubSub.subscribe(Firefly.PubSub, topic)
      {:ok, _} = Presence.track(self(), topic, user.id, %{username: user.username})
    end

    socket
  end

  # Enough to reach the first unread message (up to 200), or the page around
  # one asked for.
  defp initial_messages(channel, user, around, _socket) when is_integer(around),
    do: Chat.messages(channel, user, around: around)

  defp initial_messages(channel, user, nil, socket) do
    unread =
      Enum.find_value(
        socket.assigns.sidebar_entries,
        0,
        &(&1.channel.id == channel.id && &1.unread)
      )

    limit = min(max(50, unread + 10), 200)
    Chat.messages(channel, user, limit: limit)
  end

  defp oldest_id([]), do: nil
  defp oldest_id([first | _]), do: first.id

  defp newer?(_channel, _user, []), do: false

  defp newer?(channel, user, messages),
    do: Chat.messages(channel, user, after: List.last(messages).id, limit: 1) != []

  defp focus(around, _first_unread) when is_integer(around), do: "chat-message-#{around}"
  defp focus(nil, first_unread) when is_integer(first_unread), do: "new-messages-divider"
  defp focus(nil, nil), do: nil

  defp perms(channel, user, admin?) do
    %{
      admin?: admin?,
      post?: Chat.can?(user, :post_message, channel),
      pin?: if(Channel.direct?(channel), do: true, else: admin?),
      translate?: AI.available?(user, "translate"),
      summarize?: AI.available?(user, "summarize")
    }
  end

  defp leave_channel(%{assigns: %{channel: %Channel{} = channel}} = socket) do
    topic = Chat.presence_topic(channel)

    if connected?(socket) do
      Presence.untrack(self(), topic, socket.assigns.current_user.id)
      Phoenix.PubSub.unsubscribe(Firefly.PubSub, topic)
    end

    socket
    |> assign(channel: nil, pane: nil, thread_original: nil, present: [])
    |> stream(:messages, [], reset: true)
  end

  defp leave_channel(socket), do: socket

  defp open_thread(%{assigns: %{channel: %Channel{} = channel}} = socket, message_id) do
    user = socket.assigns.current_user

    case Chat.get_message(parse_id(message_id) || 0) do
      %{channel_id: id} = original when id == channel.id ->
        original = Chat.display(original)
        thread = original.thread_id && Chat.get_thread(original.thread_id)
        messages = if thread, do: Chat.thread_messages(thread, user), else: [original]
        if thread && connected?(socket), do: Chat.mark_thread_read(thread, user)

        socket
        |> assign(pane: :thread, thread_original: original)
        |> assign_form(:thread_form, "")
        |> stream(:thread_messages, messages, reset: true)

      _other ->
        socket
        |> put_flash(:error, "Message not found.")
        |> push_patch(to: channel_path(channel))
    end
  end

  defp open_thread(socket, _message_id), do: socket

  defp close_thread(%{assigns: %{pane: :thread}} = socket),
    do:
      socket
      |> assign(pane: nil, thread_original: nil)
      |> stream(:thread_messages, [], reset: true)

  defp close_thread(socket), do: socket

  ## Sidebar

  defp load_sidebar(socket) do
    %{channels: channels, direct: direct} = Chat.my_channels(socket.assigns.current_user)

    socket
    |> assign(sidebar_channels: channels, sidebar_direct: direct)
    |> assign(:sidebar_entries, channels ++ direct)
    |> then(
      &Enum.reduce(channels ++ direct, &1, fn entry, socket ->
        subscribe(socket, entry.channel)
      end)
    )
  end

  defp subscribe(socket, channel) do
    if connected?(socket) and not MapSet.member?(socket.assigns.subscribed, channel.id) do
      Chat.subscribe(channel)
      update(socket, :subscribed, &MapSet.put(&1, channel.id))
    else
      socket
    end
  end

  defp load_browse(socket) do
    socket
    |> assign(:browse, Chat.browse_channels(socket.assigns.current_user))
    |> assign(:categories, if(socket.assigns.admin?, do: Discussion.list_categories(), else: []))
  end

  ## Live events

  @impl true
  def handle_info({:message_created, message}, socket) do
    socket = socket |> drop_typing(message.user_id) |> load_sidebar()

    if current?(socket, message.channel_id),
      do: {:noreply, message_arrived(socket, message)},
      else: {:noreply, socket}
  end

  def handle_info({:message_updated, message}, socket) do
    socket = load_sidebar(socket)

    if current?(socket, message.channel_id) do
      {:noreply,
       socket
       |> stream_insert(:messages, message, update_only: true)
       |> stream_insert(:thread_messages, message, update_only: true)
       |> refresh_pane()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:channel_updated, channel}, socket) do
    socket = load_sidebar(socket)

    if current?(socket, channel.id) do
      user = socket.assigns.current_user

      {:noreply,
       assign(socket,
         channel: channel,
         page_title: Chat.title(channel, user),
         perms: perms(channel, user, socket.assigns.admin?)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:typing, %{channel_id: id, user_id: user_id} = who}, socket) do
    if current?(socket, id) and user_id != socket.assigns.current_user.id do
      Process.send_after(self(), :expire_typing, :timer.seconds(@typing_seconds))
      at = System.monotonic_time(:second)
      {:noreply, update(socket, :typing, &Map.put(&1, user_id, Map.put(who, :at, at)))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:expire_typing, socket) do
    cutoff = System.monotonic_time(:second) - @typing_seconds

    {:noreply, update(socket, :typing, &Map.reject(&1, fn {_id, who} -> who.at <= cutoff end))}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    case socket.assigns.channel do
      nil -> {:noreply, socket}
      channel -> {:noreply, assign(socket, :present, present(channel))}
    end
  end

  def handle_info(msg, socket) when msg in [:channels_changed] do
    socket = load_sidebar(socket)

    if socket.assigns.live_action == :index,
      do: {:noreply, load_browse(socket)},
      else: {:noreply, socket}
  end

  def handle_info({:chat_read, _channel_id}, socket), do: {:noreply, load_sidebar(socket)}

  def handle_info({:ai_delta, ref, text}, %{assigns: %{ai: %{ref: ref}}} = socket),
    do: {:noreply, update(socket, :ai, &%{&1 | result: append_text(&1.result, text)})}

  def handle_info({:ai_delta, _stale, _text}, socket), do: {:noreply, socket}

  # An AI summary or translation finished; one for a pane since closed or
  # replaced is dropped.
  @impl true
  def handle_async({:ai, ref}, result, %{assigns: %{pane: :ai, ai: %{ref: ref}}} = socket),
    do: {:noreply, update(socket, :ai, &%{&1 | result: ai_outcome(result)})}

  def handle_async({:ai, _ref}, _result, socket), do: {:noreply, socket}

  defp current?(socket, channel_id),
    do: match?(%Channel{id: ^channel_id}, socket.assigns.channel)

  defp drop_typing(socket, user_id), do: update(socket, :typing, &Map.delete(&1, user_id))

  defp present(channel) do
    channel
    |> Chat.presence_topic()
    |> Presence.list()
    |> Enum.map(fn {_id, %{metas: [meta | _]}} -> meta.username end)
    |> Enum.sort()
  end

  # A thread reply updates its original message in the stream (its reply
  # count) and joins an open thread pane; anything else joins the stream.
  defp message_arrived(socket, message) do
    %{channel: channel, current_user: user} = socket.assigns

    if message.thread && message.thread.original_message_id != message.id do
      original = Chat.display(Chat.get_message(message.thread.original_message_id))

      socket =
        socket
        |> assign(:thread_unread, Chat.thread_unread_counts(channel, user))
        |> stream_insert(:messages, original, update_only: true)

      if thread_open?(socket, message.thread.original_message_id) do
        Chat.mark_thread_read(message.thread, user)

        socket
        |> assign(:thread_unread, Chat.thread_unread_counts(channel, user))
        |> stream_insert(:thread_messages, message)
      else
        socket
      end
    else
      socket =
        if message.user_id == user.id,
          do: assign(socket, :membership, Chat.membership(channel, user)),
          else: socket

      if socket.assigns.membership, do: Chat.mark_read(channel, user, message.id)
      if socket.assigns.has_newer, do: socket, else: stream_insert(socket, :messages, message)
    end
  end

  defp thread_open?(socket, original_id),
    do: match?(%{pane: :thread, thread_original: %{id: ^original_id}}, socket.assigns)

  defp refresh_pane(%{assigns: %{pane: :pinned}} = socket), do: load_pane(socket, :pinned)
  defp refresh_pane(%{assigns: %{pane: :threads}} = socket), do: load_pane(socket, :threads)
  defp refresh_pane(socket), do: socket

  ## Writing

  @impl true
  def handle_event("draft", %{"message" => %{"body" => body}}, socket),
    do: {:noreply, assign_form(socket, :form, body)}

  def handle_event("draft", %{"thread_message" => %{"body" => body}}, socket),
    do: {:noreply, assign_form(socket, :thread_form, body)}

  def handle_event("draft", _params, socket), do: {:noreply, socket}

  def handle_event("send", %{"message" => %{"body" => body}}, socket) do
    reply_to = socket.assigns.reply_to
    attrs = %{"body" => body, "in_reply_to_id" => reply_to && reply_to.id}

    send_message(socket, attrs, :form, "chat-form")
  end

  def handle_event("send_thread", %{"thread_message" => %{"body" => body}}, socket) do
    attrs = %{"body" => body, "thread_of" => socket.assigns.thread_original.id}
    send_message(socket, attrs, :thread_form, "chat-thread-form")
  end

  def handle_event("typing", params, socket) do
    if channel = socket.assigns.channel,
      do: Chat.typing(channel, socket.assigns.current_user, parse_id(params["thread"]))

    {:noreply, socket}
  end

  def handle_event("reply", %{"id" => id}, socket) do
    case channel_message(socket, id) do
      nil -> {:noreply, socket}
      message -> {:noreply, assign(socket, :reply_to, Chat.display(message))}
    end
  end

  def handle_event("cancel_reply", _params, socket),
    do: {:noreply, assign(socket, :reply_to, nil)}

  def handle_event("edit", %{"id" => id}, socket) do
    case channel_message(socket, id) do
      nil -> {:noreply, socket}
      message -> {:noreply, socket |> assign(:editing, message.id) |> rerender(message)}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    case socket.assigns.editing && channel_message(socket, socket.assigns.editing) do
      nil -> {:noreply, socket}
      message -> {:noreply, socket |> assign(:editing, nil) |> rerender(message)}
    end
  end

  def handle_event("save_edit", %{"message_id" => id, "edit" => %{"body" => body}}, socket) do
    with %{} = message <- channel_message(socket, id),
         {:ok, _edited} <-
           Chat.edit_message(message, socket.assigns.current_user, %{"body" => body}) do
      {:noreply, assign(socket, :editing, nil)}
    else
      nil -> {:noreply, socket}
      error -> {:noreply, refused(socket, error)}
    end
  end

  def handle_event(action, %{"id" => id}, socket) when action in ~w(delete restore pin unpin) do
    fun =
      %{
        "delete" => &Chat.delete_message/2,
        "restore" => &Chat.restore_message/2,
        "pin" => &Chat.pin_message/2,
        "unpin" => &Chat.unpin_message/2
      }[action]

    act(socket, id, &fun.(&1, socket.assigns.current_user))
  end

  def handle_event("react", %{"id" => id, "emoji" => emoji}, socket),
    do: act(socket, id, &Chat.toggle_reaction(&1, socket.assigns.current_user, emoji))

  def handle_event("load_older", _params, socket) do
    %{channel: channel, current_user: user, oldest_id: oldest} = socket.assigns

    if channel && oldest && socket.assigns.has_more do
      older = Chat.messages(channel, user, before: oldest)

      {:reply, %{},
       socket
       |> assign(
         has_more: length(older) >= 50,
         oldest_id: if(older == [], do: oldest, else: hd(older).id)
       )
       |> stream(:messages, Enum.reverse(older), at: 0)}
    else
      {:reply, %{}, socket}
    end
  end

  def handle_event("jump_latest", _params, socket),
    do: {:noreply, push_patch(socket, to: channel_path(socket.assigns.channel))}

  ## Panes

  def handle_event("pane", %{"pane" => pane}, socket)
      when pane in ~w(threads pinned search settings) do
    pane = String.to_existing_atom(pane)

    cond do
      socket.assigns.pane == :thread ->
        {:noreply,
         socket |> push_patch(to: channel_path(socket.assigns.channel)) |> load_pane(pane)}

      socket.assigns.pane == pane ->
        {:noreply, assign(socket, :pane, nil)}

      true ->
        {:noreply, load_pane(socket, pane)}
    end
  end

  def handle_event("close_pane", _params, %{assigns: %{pane: :thread}} = socket),
    do: {:noreply, push_patch(socket, to: channel_path(socket.assigns.channel))}

  def handle_event("close_pane", _params, socket), do: {:noreply, assign(socket, :pane, nil)}

  def handle_event("summarize", _params, %{assigns: %{channel: %Channel{} = channel}} = socket) do
    user = socket.assigns.current_user
    {:noreply, ai_pane(socket, "Summary", &Summaries.channel(channel, user, stream: &1))}
  end

  def handle_event("translate", %{"id" => id}, socket) do
    %{current_user: user, language: language} = socket.assigns

    case channel_message(socket, id) do
      nil ->
        {:noreply, socket}

      message ->
        {:noreply,
         ai_pane(
           socket,
           "Translation",
           &Translations.message(message, user, language, stream: &1)
         )}
    end
  end

  def handle_event("history", %{"id" => id}, socket) do
    case channel_message(socket, id) do
      nil ->
        {:noreply, socket}

      message ->
        {:noreply, assign(socket, pane: :history, history: {message, Chat.revisions(message)})}
    end
  end

  def handle_event("flag_form", %{"id" => id}, socket) do
    case channel_message(socket, id) do
      nil -> {:noreply, socket}
      message -> {:noreply, assign(socket, pane: :flag, flagging: Chat.display(message))}
    end
  end

  def handle_event("flag", %{"flag" => params}, socket) do
    with %{} = message <- channel_message(socket, params["message_id"]),
         {:ok, _flag} <- Chat.flag_message(message, socket.assigns.current_user, params) do
      {:noreply,
       socket |> assign(:pane, nil) |> put_flash(:info, "Thanks: staff will take a look.")}
    else
      nil ->
        {:noreply, socket}

      {:error, :already_flagged} ->
        {:noreply, put_flash(socket, :error, "You already flagged this message.")}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    with %{} = member <- Firefly.Accounts.get_user(id),
         :ok <- Chat.remove_member(socket.assigns.channel, member, admin) do
      {:noreply,
       socket |> load_pane(:settings) |> put_flash(:info, "Removed @#{member.username}.")}
    else
      nil -> {:noreply, socket}
      error -> {:noreply, refused(socket, error)}
    end
  end

  def handle_event("search", %{"q" => q} = params, socket) do
    user = socket.assigns.current_user

    case RateLimit.check_search(user, nil) do
      :ok ->
        opts = if params["here"] == "true", do: [channel: socket.assigns.channel], else: []
        {:noreply, assign(socket, search: q, search_results: Chat.search(user, q, opts))}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, RateLimit.message())}
    end
  end

  ## Membership and channels

  def handle_event("follow", %{"id" => id}, socket) do
    with %Channel{} = channel <- Chat.get_channel(id),
         :ok <- Chat.follow(channel, socket.assigns.current_user) do
      {:noreply, socket |> load_sidebar() |> load_browse() |> refresh_membership()}
    else
      _ -> {:noreply, put_flash(socket, :error, "You can't follow that channel.")}
    end
  end

  def handle_event("unfollow", %{"id" => id}, socket) do
    case Chat.get_channel(id) do
      nil ->
        {:noreply, socket}

      channel ->
        :ok = Chat.unfollow(channel, socket.assigns.current_user)
        {:noreply, socket |> load_sidebar() |> load_browse() |> refresh_membership()}
    end
  end

  def handle_event("membership", %{"membership" => params}, socket) do
    case Chat.update_membership(socket.assigns.channel, socket.assigns.current_user, params) do
      {:ok, membership} -> {:noreply, socket |> assign(:membership, membership) |> load_sidebar()}
      _error -> {:noreply, put_flash(socket, :error, "Follow the channel first.")}
    end
  end

  def handle_event("create_channel", %{"channel" => params}, socket) do
    case Chat.create_channel(params, socket.assigns.current_user) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(:channel_form, to_form(Chat.change_channel()))
         |> put_flash(:info, "Channel created.")
         |> push_patch(to: channel_path(channel))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :channel_form, to_form(changeset))}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  def handle_event("update_channel", %{"channel" => params}, socket) do
    case Chat.update_channel(socket.assigns.channel, params, socket.assigns.current_user) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(channel: channel, channel_form: to_form(Chat.change_channel(channel)))
         |> put_flash(:info, "Channel saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :channel_form, to_form(changeset))}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  def handle_event("set_status", %{"status" => status}, socket) do
    case Chat.set_status(socket.assigns.channel, status, socket.assigns.current_user) do
      {:ok, channel} ->
        {:noreply,
         socket
         |> assign(
           channel: channel,
           perms: perms(channel, socket.assigns.current_user, socket.assigns.admin?)
         )
         |> put_flash(:info, "Channel is now #{status_label(status)}.")}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  def handle_event("start_dm", %{"dm" => %{"usernames" => usernames}}, socket) do
    names = String.split(usernames, ~r/[\s,]+/, trim: true)

    case Chat.direct_channel(socket.assigns.current_user, names) do
      {:ok, channel} ->
        {:noreply, push_patch(socket, to: channel_path(channel))}

      {:error, message} when is_binary(message) ->
        {:noreply,
         assign(
           socket,
           :dm_form,
           to_form(%{"usernames" => usernames},
             as: :dm,
             errors: [usernames: {message, []}],
             action: :validate
           )
         )}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  defp refresh_membership(%{assigns: %{channel: %Channel{} = channel}} = socket),
    do: assign(socket, :membership, Chat.membership(channel, socket.assigns.current_user))

  defp refresh_membership(socket), do: socket

  defp load_pane(socket, :threads),
    do:
      assign(socket,
        pane: :threads,
        threads: Chat.threads(socket.assigns.channel, socket.assigns.current_user)
      )

  defp load_pane(socket, :pinned),
    do:
      assign(socket,
        pane: :pinned,
        pinned: Chat.pinned_messages(socket.assigns.channel, socket.assigns.current_user)
      )

  defp load_pane(socket, :settings) do
    channel = socket.assigns.channel

    assign(socket,
      pane: :settings,
      members: Chat.members(channel),
      categories: if(socket.assigns.admin?, do: Discussion.list_categories(), else: []),
      channel_form: to_form(Chat.change_channel(channel))
    )
  end

  defp load_pane(socket, :search),
    do: assign(socket, pane: :search, search: nil, search_results: [])

  ## Helpers

  defp send_message(socket, attrs, form, form_id) do
    case Chat.send_message(socket.assigns.channel, socket.assigns.current_user, attrs) do
      {:ok, _message} ->
        socket = if form == :form, do: assign(socket, :reply_to, nil), else: socket
        {:noreply, socket |> assign_form(form, "") |> push_event("chat_sent", %{form: form_id})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form, to_form(changeset, as: form_name(form)))}

      error ->
        {:noreply, refused(socket, error)}
    end
  end

  defp form_name(:form), do: :message
  defp form_name(:thread_form), do: :thread_message

  defp assign_form(socket, form, body),
    do: assign(socket, form, to_form(%{"body" => body}, as: form_name(form)))

  # Acts on a message of the open channel, or says why not.
  defp act(socket, id, fun) do
    case channel_message(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Message not found.")}

      message ->
        case fun.(message) do
          {:ok, _message} -> {:noreply, socket}
          error -> {:noreply, refused(socket, error)}
        end
    end
  end

  # Opens the AI pane on `run`'s result (a summary or translation), which
  # streams in from a task.
  defp ai_pane(socket, title, run) do
    ref = make_ref()
    page = self()

    socket
    |> assign(pane: :ai, ai: %{ref: ref, title: title, result: %{status: :loading, text: ""}})
    |> start_async({:ai, ref}, fn -> run.(&send(page, {:ai_delta, ref, &1})) end)
  end

  defp channel_message(%{assigns: %{channel: %Channel{id: channel_id}}}, id) do
    case Chat.get_message(parse_id(id) || 0) do
      %{channel_id: ^channel_id} = message -> message
      _other -> nil
    end
  end

  defp channel_message(_socket, _id), do: nil

  defp rerender(socket, message) do
    message = Chat.display(message)

    socket
    |> stream_insert(:messages, message, update_only: true)
    |> stream_insert(:thread_messages, message, update_only: true)
  end

  defp refused(socket, {:error, :unauthorized}),
    do: put_flash(socket, :error, denied_message(socket.assigns.current_user))

  defp refused(socket, {:error, :not_found}),
    do: put_flash(socket, :error, "That message is gone.")

  defp refused(socket, {:error, :invalid_emoji}),
    do: put_flash(socket, :error, "That's not an emoji.")

  defp refused(socket, {:error, %Ecto.Changeset{} = changeset}) do
    message =
      Enum.map_join(changeset.errors, ", ", fn {field, error} ->
        "#{field} #{translate_error(error)}"
      end)

    put_flash(socket, :error, message)
  end

  defp refused(socket, {:error, reason}), do: put_flash(socket, :error, Posting.message(reason))

  defp handle_progress(:attachment, entry, socket) do
    Editor.attachment_progress(socket, entry, fn socket, markdown ->
      body = Editor.append(socket.assigns.form[:body].value, markdown)
      {:noreply, assign_form(socket, :form, body)}
    end)
  end

  defp parse_id(nil), do: nil
  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> id
      _other -> nil
    end
  end

  defp channel_path(%Channel{} = channel), do: ~p"/chat/c/#{channel.slug || "dm"}/#{channel.id}"

  defp thread_path(%Channel{} = channel, message_id),
    do: ~p"/chat/c/#{channel.slug || "dm"}/#{channel.id}/t/#{message_id}"

  defp status_label("read_only"), do: "read-only"
  defp status_label(status), do: status

  defp typing_text(typing, thread_id) do
    names = for {_id, who} <- typing, who.thread_id == thread_id, do: who.username

    case Enum.sort(names) do
      [] -> nil
      [name] -> "#{name} is typing…"
      [a, b] -> "#{a} and #{b} are typing…"
      _many -> "Several people are typing…"
    end
  end

  ## Rendering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)} full>
      <div id="chat" class="flex h-[calc(100dvh-4rem)] min-h-0">
        <.sidebar {assigns} />
        <section class={["flex min-w-0 flex-1 flex-col", !@channel && @live_action not in [:index, :new_dm] && "hidden md:flex"]}>
          <.browse :if={@live_action == :index} {assigns} />
          <.new_dm :if={@live_action == :new_dm} {assigns} />
          <.channel_view :if={@channel} {assigns} />
        </section>
        <.side_pane :if={@channel && @pane} {assigns} />
        <div id="reaction-picker" phx-hook="ReactionPicker" phx-update="ignore" data-custom-emoji={ChatComponents.custom_emoji_json()}>
          <button type="button" data-toggle hidden aria-hidden="true"></button>
          <ChatComponents.emoji_panel class="fixed right-8 bottom-24 z-50" />
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp sidebar(assigns) do
    ~H"""
    <aside
      id="chat-sidebar"
      class={["w-full shrink-0 overflow-y-auto border-r border-base-300 p-3 md:w-64", @channel && "hidden md:block"]}
    >
      <div class="mb-2 flex items-center gap-1">
        <h1 class="flex-1 text-lg font-bold">Chat</h1>
        <.link patch={~p"/chat"} class="btn btn-ghost btn-xs" aria-label="Browse channels">
          <.icon name="hero-squares-2x2" class="size-4" />
        </.link>
        <.link :if={@can_dm?} patch={~p"/chat/new-message"} class="btn btn-ghost btn-xs" aria-label="New direct message">
          <.icon name="hero-pencil-square" class="size-4" />
        </.link>
      </div>
      <ul class="menu menu-sm w-full p-0">
        <li class="menu-title">Channels</li>
        <li :if={@sidebar_channels == []} class="px-3 text-xs text-base-content/60">
          <.link patch={~p"/chat"}>Browse channels to follow</.link>
        </li>
        <li :for={entry <- @sidebar_channels} id={"sidebar-channel-#{entry.channel.id}"}>
          <.link patch={channel_path(entry.channel)} class={[@channel && @channel.id == entry.channel.id && "menu-active"]}>
            <span class="opacity-60">#</span>
            <span class="flex-1 truncate">{entry.channel.name}</span>
            <.unread entry={entry} />
          </.link>
        </li>
        <li class="menu-title mt-2">Direct messages</li>
        <li :for={entry <- @sidebar_direct} id={"sidebar-channel-#{entry.channel.id}"}>
          <.link patch={channel_path(entry.channel)} class={[@channel && @channel.id == entry.channel.id && "menu-active"]}>
            <.icon name="hero-user" class="size-4 opacity-60" />
            <span class="flex-1 truncate">{Chat.title(entry.channel, @current_user)}</span>
            <.unread entry={entry} />
          </.link>
        </li>
      </ul>
    </aside>
    """
  end

  attr :entry, :map, required: true

  defp unread(assigns) do
    ~H"""
    <.icon :if={@entry.membership.muted} name="hero-bell-slash" class="size-3 opacity-50" />
    <span :if={@entry.mentions > 0} class="badge badge-primary badge-xs" aria-label={"#{@entry.mentions} mentions"}>
      @{@entry.mentions}
    </span>
    <span
      :if={@entry.mentions == 0 && @entry.unread > 0 && !@entry.membership.muted}
      class="badge badge-neutral badge-xs"
      aria-label={"#{@entry.unread} unread"}
    >
      {@entry.unread}
    </span>
    """
  end

  defp browse(assigns) do
    ~H"""
    <div class="flex-1 space-y-6 overflow-y-auto p-6">
      <h2 class="text-2xl font-bold tracking-tight">Channels</h2>
      <p :if={@browse == []} class="text-base-content/60">No channels yet.</p>
      <ul id="browse-channels" class="divide-y divide-base-300 rounded-box border border-base-300">
        <li :for={{channel, following?} <- @browse} id={"browse-channel-#{channel.id}"} class="flex items-center gap-3 p-3">
          <div class="min-w-0 flex-1">
            <.link patch={channel_path(channel)} class="font-semibold hover:text-primary"># {channel.name}</.link>
            <span :if={channel.status != "open"} class="badge badge-ghost badge-sm ml-1">{status_label(channel.status)}</span>
            <p :if={channel.description} class="truncate text-sm text-base-content/60">{channel.description}</p>
          </div>
          <button :if={!following?} phx-click="follow" phx-value-id={channel.id} class="btn btn-primary btn-sm">Follow</button>
          <button :if={following?} phx-click="unfollow" phx-value-id={channel.id} class="btn btn-ghost btn-sm">Leave</button>
        </li>
      </ul>
      <section :if={@admin?} class="space-y-3">
        <h3 class="text-lg font-semibold">New channel</h3>
        <.form for={@channel_form} id="new-channel-form" phx-submit="create_channel" class="space-y-2">
          <.channel_fields form={@channel_form} categories={@categories} />
          <.button variant="primary">Create channel</.button>
        </.form>
      </section>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :categories, :list, required: true

  defp channel_fields(assigns) do
    ~H"""
    <.input field={@form[:name]} label="Name" />
    <.input field={@form[:slug]} label="Slug (blank: from the name)" />
    <.input field={@form[:description]} type="textarea" label="Description" rows="2" />
    <.input
      field={@form[:category_id]}
      type="select"
      label="Category (members who may read it may join; blank: everyone)"
      prompt="None"
      options={Enum.map(@categories, &{&1.title, &1.id})}
    />
    <.input field={@form[:allow_channel_wide_mentions]} type="checkbox" label="Allow @here and @all" />
    """
  end

  defp new_dm(assigns) do
    ~H"""
    <div class="flex-1 space-y-4 overflow-y-auto p-6">
      <h2 class="text-2xl font-bold tracking-tight">New direct message</h2>
      <p :if={!@can_dm?} class="text-base-content/60">You can't start direct messages yet.</p>
      <.form :if={@can_dm?} for={@dm_form} id="new-dm-form" phx-submit="start_dm" class="space-y-3">
        <.input field={@dm_form[:usernames]} label="To (usernames)" placeholder="@alice, @bob" />
        <.button variant="primary">Start</.button>
      </.form>
    </div>
    """
  end

  defp channel_view(assigns) do
    ~H"""
    <header class="flex flex-wrap items-center gap-2 border-b border-base-300 px-4 py-2">
      <.link patch={~p"/chat"} class="btn btn-ghost btn-xs md:hidden" aria-label="Back to channels">
        <.icon name="hero-arrow-left" class="size-4" />
      </.link>
      <h2 id="channel-title" class="font-semibold">
        <span :if={!Channel.direct?(@channel)} class="opacity-60">#</span>{Chat.title(@channel, @current_user)}
      </h2>
      <span :if={@channel.status != "open"} id="channel-status" class="badge badge-warning badge-sm">
        {status_label(@channel.status)}
      </span>
      <p :if={@channel.description} class="hidden truncate text-sm text-base-content/60 lg:block">
        {@channel.description}
      </p>
      <button
        :if={@perms.summarize?}
        id="summarize-channel"
        type="button"
        phx-click="summarize"
        class="btn btn-ghost btn-xs"
        title="Summarize what you haven't read"
      >
        <.icon name="hero-sparkles" class="size-4" /> Summarize
      </button>
      <span id="presence" class="ml-auto text-xs text-base-content/60" title={Enum.join(@present, ", ")}>
        <.icon name="hero-signal-micro" class="size-3 text-success" /> {length(@present)} here
      </span>
      <div class="join">
        <button :for={{pane, icon, label} <- [{"threads", "hero-chat-bubble-left-right", "Threads"}, {"pinned", "hero-bookmark", "Pinned"}, {"search", "hero-magnifying-glass", "Search"}, {"settings", "hero-cog-6-tooth", "Settings"}]}
          type="button"
          phx-click="pane"
          phx-value-pane={pane}
          class={["btn btn-ghost btn-xs join-item", to_string(@pane) == pane && "btn-active"]}
          aria-label={label}
          title={label}
        >
          <.icon name={icon} class="size-4" />
        </button>
      </div>
    </header>
    <div id="chat-scroll" phx-hook="ChatScroll" data-has-more={to_string(@has_more)} data-focus={@focus} class="flex-1 overflow-y-auto px-2 py-2">
      <div :if={@has_more} class="py-2 text-center">
        <button id="load-older" type="button" phx-click="load_older" class="btn btn-ghost btn-xs">Load older messages</button>
      </div>
      <ol id="chat-messages" phx-update="stream">
        <li :for={{dom_id, message} <- @streams.messages} id={dom_id}>
          <ChatComponents.message
            message={message}
            user={@current_user}
            perms={@perms}
            editing={@editing == message.id}
            unread_divider={message.id == @first_unread}
            thread_unread={Map.get(@thread_unread, message.thread_id, 0)}
            thread_path={thread_path(@channel, message.id)}
          />
        </li>
      </ol>
      <div :if={@has_newer} class="py-2 text-center">
        <button type="button" phx-click="jump_latest" class="btn btn-primary btn-xs">Jump to latest</button>
      </div>
    </div>
    <p id="typing" class="h-5 px-4 text-xs italic text-base-content/60">{typing_text(@typing, nil)}</p>
    <ChatComponents.composer
      :if={@perms.post?}
      form={@form}
      id="chat-form"
      submit="send"
      uploads={@uploads}
      placeholder={"Message #{Chat.title(@channel, @current_user)}"}
    >
      <:header>
        <div :if={@reply_to} id="replying-to" class="mb-2 flex items-center gap-2 text-xs text-base-content/70">
          <.icon name="hero-arrow-uturn-left" class="size-3" />
          <span class="truncate">
            Replying to <strong :if={@reply_to.user}>@{@reply_to.user.username}</strong>: {ChatComponents.excerpt(@reply_to)}
          </span>
          <button type="button" phx-click="cancel_reply" class="btn btn-ghost btn-xs" aria-label="Cancel reply">
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </div>
      </:header>
    </ChatComponents.composer>
    <p :if={!@perms.post?} id="channel-closed" class="border-t border-base-300 p-4 text-center text-sm text-base-content/60">
      {cond do
        @channel.status == "closed" -> "This channel is closed: only staff can post."
        @channel.status in ["read_only", "archived"] -> "This channel is #{status_label(@channel.status)}."
        true -> "You can't post here."
      end}
    </p>
    """
  end

  defp side_pane(assigns) do
    ~H"""
    <aside id="chat-pane" class="flex w-full shrink-0 flex-col border-l border-base-300 bg-base-100 md:w-96">
      <header class="flex items-center gap-2 border-b border-base-300 px-4 py-2">
        <h2 class="flex-1 font-semibold">
          {%{thread: "Thread", threads: "Threads", pinned: "Pinned messages", search: "Search", settings: "Settings", history: "Edit history", flag: "Flag message", ai: "AI"}[@pane]}
        </h2>
        <button type="button" phx-click="close_pane" class="btn btn-ghost btn-xs" aria-label="Close">
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </header>
      <.thread_pane :if={@pane == :thread} {assigns} />
      <div :if={@pane != :thread} class="flex-1 space-y-3 overflow-y-auto p-3">
        <.threads_pane :if={@pane == :threads} {assigns} />
        <.pinned_pane :if={@pane == :pinned} {assigns} />
        <.search_pane :if={@pane == :search} {assigns} />
        <.settings_pane :if={@pane == :settings} {assigns} />
        <.history_pane :if={@pane == :history} {assigns} />
        <.flag_pane :if={@pane == :flag} {assigns} />
        <.ai_result :if={@pane == :ai} id="chat-ai" title={@ai.title} result={@ai.result} viewer={@current_user} />
      </div>
    </aside>
    """
  end

  defp thread_pane(assigns) do
    ~H"""
    <ol id="thread-messages" phx-update="stream" class="flex-1 overflow-y-auto p-2">
      <li :for={{dom_id, message} <- @streams.thread_messages} id={"thread-" <> dom_id}>
        <ChatComponents.message
          message={message}
          user={@current_user}
          perms={@perms}
          editing={@editing == message.id}
          in_thread
        />
      </li>
    </ol>
    <p id="thread-typing" class="h-5 px-4 text-xs italic text-base-content/60">
      {typing_text(@typing, @thread_original.thread_id)}
    </p>
    <ChatComponents.composer
      :if={@perms.post?}
      form={@thread_form}
      id="chat-thread-form"
      submit="send_thread"
      thread_id={@thread_original.thread_id}
      placeholder="Reply in thread"
    />
    """
  end

  defp threads_pane(assigns) do
    ~H"""
    <p :if={@threads == []} class="text-sm text-base-content/60">No threads yet.</p>
    <.link
      :for={entry <- @threads}
      patch={thread_path(@channel, entry.original.id)}
      class="block rounded-box border border-base-300 p-2 text-sm hover:bg-base-200"
    >
      <div class="flex items-center gap-2">
        <strong :if={entry.original.user}>@{entry.original.user.username}</strong>
        <span class="text-xs text-base-content/60">{entry.original.reply_count} replies</span>
        <span :if={entry.unread > 0} class="badge badge-primary badge-xs ml-auto">{entry.unread} new</span>
      </div>
      <p class="truncate">{ChatComponents.excerpt(entry.original)}</p>
    </.link>
    """
  end

  defp pinned_pane(assigns) do
    ~H"""
    <p :if={@pinned == []} class="text-sm text-base-content/60">Nothing is pinned.</p>
    <div :for={message <- @pinned} id={"pinned-#{message.id}"} class="rounded-box border border-base-300 p-2 text-sm">
      <div class="flex items-center gap-2">
        <strong :if={message.user}>@{message.user.username}</strong>
        <.link patch={channel_path(@channel) <> "?message=#{message.id}"} class="link link-hover ml-auto text-xs">Jump</.link>
      </div>
      <.markdown id={"pinned-#{message.id}-body"} body={message.body} viewer={@current_user} />
    </div>
    """
  end

  defp search_pane(assigns) do
    ~H"""
    <.form for={%{}} id="chat-search-form" phx-submit="search" class="space-y-2">
      <label class="input input-sm w-full">
        <.icon name="hero-magnifying-glass" class="size-4 opacity-60" />
        <input type="search" name="q" value={@search} placeholder="Search chat" aria-label="Search chat" />
      </label>
      <label class="label text-xs">
        <input type="checkbox" name="here" value="true" class="checkbox checkbox-xs" /> This channel only
      </label>
    </.form>
    <p :if={@search && @search_results == []} class="text-sm text-base-content/60">No messages found.</p>
    <.link
      :for={message <- @search_results}
      id={"search-result-#{message.id}"}
      patch={channel_path(message.channel) <> "?message=#{message.id}"}
      class="block rounded-box border border-base-300 p-2 text-sm hover:bg-base-200"
    >
      <div class="flex gap-2 text-xs text-base-content/60">
        <span>{Chat.title(message.channel, @current_user)}</span>
        <span :if={message.user}>@{message.user.username}</span>
      </div>
      <p class="truncate">{ChatComponents.excerpt(message)}</p>
    </.link>
    """
  end

  defp history_pane(assigns) do
    ~H"""
    <%= with {message, revisions} <- @history do %>
      <div :for={revision <- revisions} class="rounded-box border border-base-300 p-2 text-sm">
        <div class="text-xs text-base-content/60">
          Before an edit by <span :if={revision.user}>@{revision.user.username}</span>
          <.time_ago id={"revision-#{revision.id}-time"} at={revision.inserted_at} />
        </div>
        <p class="whitespace-pre-wrap">{revision.body}</p>
      </div>
      <div class="rounded-box border border-primary/40 p-2 text-sm">
        <div class="text-xs text-base-content/60">Now</div>
        <p class="whitespace-pre-wrap">{message.body}</p>
      </div>
    <% end %>
    """
  end

  defp flag_pane(assigns) do
    ~H"""
    <blockquote class="border-l-2 border-base-300 pl-2 text-sm">{ChatComponents.excerpt(@flagging)}</blockquote>
    <.form for={%{}} as={:flag} id="flag-form" phx-submit="flag" class="space-y-2">
      <input type="hidden" name="flag[message_id]" value={@flagging.id} />
      <.input
        name="flag[reason]"
        value="inappropriate"
        type="select"
        label="What's wrong?"
        options={Enum.map(Flag.reasons(), &{Flag.reason_label(&1), &1})}
      />
      <.input name="flag[note]" value="" type="textarea" label="Note for staff (optional)" rows="2" />
      <.button variant="primary">Flag</.button>
    </.form>
    """
  end

  defp settings_pane(assigns) do
    ~H"""
    <section class="space-y-2">
      <%= if @membership && @membership.following do %>
        <.form for={to_form(%{"muted" => to_string(@membership.muted), "notification_level" => @membership.notification_level}, as: :membership)} id="membership-form" phx-change="membership">
          <.input name="membership[muted]" value={@membership.muted} type="checkbox" label="Mute (unread messages don't count)" />
          <.input
            name="membership[notification_level]"
            value={@membership.notification_level}
            type="select"
            label="Notify me"
            options={[{"About every message", "always"}, {"When I'm mentioned", "mention"}, {"Never", "never"}]}
          />
        </.form>
        <button :if={!Channel.direct?(@channel)} phx-click="unfollow" phx-value-id={@channel.id} class="btn btn-ghost btn-sm">
          Leave channel
        </button>
        <button :if={Channel.direct?(@channel)} phx-click="unfollow" phx-value-id={@channel.id} class="btn btn-ghost btn-sm">
          Close conversation
        </button>
      <% else %>
        <button :if={!Channel.direct?(@channel)} phx-click="follow" phx-value-id={@channel.id} class="btn btn-primary btn-sm">
          Follow channel
        </button>
      <% end %>
    </section>
    <section class="space-y-1">
      <h3 class="text-sm font-semibold">Members ({length(@members)})</h3>
      <ul id="channel-members" class="flex flex-wrap gap-1">
        <li :for={member <- @members} id={"member-#{member.id}"} class="badge badge-ghost gap-1">
          <.avatar user={member} size="size-4" /> @{member.username}
          <button
            :if={@admin? && !Channel.direct?(@channel) && member.id != @current_user.id}
            type="button"
            phx-click="remove_member"
            phx-value-id={member.id}
            data-confirm={"Remove @#{member.username} from this channel?"}
            aria-label={"Remove @#{member.username}"}
          >
            <.icon name="hero-x-mark-micro" class="size-3" />
          </button>
        </li>
      </ul>
    </section>
    <section :if={@admin? && !Channel.direct?(@channel)} class="space-y-2 border-t border-base-300 pt-3">
      <h3 class="text-sm font-semibold">Staff</h3>
      <div class="flex flex-wrap gap-1">
        <button
          :for={status <- Channel.statuses()}
          :if={status != @channel.status}
          phx-click="set_status"
          phx-value-status={status}
          class="btn btn-xs"
        >
          {%{"open" => "Open", "closed" => "Close", "read_only" => "Make read-only", "archived" => "Archive"}[status]}
        </button>
      </div>
      <.form for={@channel_form} id="edit-channel-form" phx-submit="update_channel" class="space-y-2">
        <.channel_fields form={@channel_form} categories={@categories} />
        <.button>Save channel</.button>
      </.form>
    </section>
    """
  end
end
