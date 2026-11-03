defmodule FireflyWeb.UserAuth do
  @moduledoc """
  `on_mount` hooks for LiveViews:

    * `:mount_current_user` - assigns `:current_user` (or nil) from the session,
      the unread notification and conversation counts, whether they may
      chat (`:chat`, for the navigation), for admins the review
      queue's count (kept live; views can export `review_changed/1` to react
      too) and whether a newer Firefly is out, and the current path. It records the user's visit (see
      `Firefly.Accounts.Visits`) and counts a page view (see
      `Firefly.Analytics`) once the page connects.
      For a user, it also handles the theme toggle's `"set_theme"` event on
      every page, saving their theme.
      It keeps `:read_only` (see `Firefly.Backups`) live for the banner, and
      while the site is read-only refuses every event (they'd write), but
      on the backups page, where admins lift it.
    * `:require_user` - redirects to the categories page when nobody is
      logged in. Used by individual LiveViews, after the live session's
      `:mount_current_user`.
      Staff who must set up two-factor authentication first are sent to
      their security settings from any other page.
    * `:password_login` - redirects to the login page when passwords are off
      (single sign-on only, see `Firefly.Accounts.Auth.sso_only?/0`). Used by
      the password login, registration and reset pages.
  """

  use Gettext, backend: FireflyWeb.Gettext

  use FireflyWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3, assign_new: 3]
  import Phoenix.LiveView

  alias Firefly.{Accounts, Analytics, Backups, Chat, Messaging, Notifications}
  alias Firefly.Accounts.{User, Visits}
  alias Firefly.Moderation.{Posting, Review}
  alias FireflyWeb.Session

  def on_mount(:mount_current_user, _params, session, socket) do
    socket = mount_current_user(socket, session)

    # Staff who must set up two-factor (see Firefly.Accounts.TwoFactor.must_enroll?/1)
    # can only use their settings until they have.
    if socket.view != FireflyWeb.SettingsLive.Index and
         Firefly.Accounts.TwoFactor.must_enroll?(socket.assigns.current_user) do
      {:halt,
       socket
       |> put_flash(:error, gettext("Set up two-factor authentication to go on."))
       |> redirect(to: ~p"/settings/security")}
    else
      {:cont, socket}
    end
  end

  def on_mount(:require_user, params, session, socket) do
    {:cont, socket} =
      if Map.has_key?(socket.assigns, :current_user),
        do: {:cont, socket},
        else: on_mount(:mount_current_user, params, session, socket)

    if socket.assigns.current_user do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, gettext("You must be logged in to access this page."))
        |> redirect(to: ~p"/categories")

      {:halt, socket}
    end
  end

  def on_mount(:password_login, _params, _session, socket) do
    if Firefly.Accounts.Auth.password_login?() do
      {:cont, socket}
    else
      socket =
        socket
        |> put_flash(:error, gettext("Log in with single sign-on."))
        |> redirect(to: ~p"/login")

      {:halt, socket}
    end
  end

  defp mount_current_user(socket, session) do
    socket
    |> assign_new(:current_user, fn -> Session.user_from_id(session["current_user"]) end)
    |> record_visit()
    |> record_client()
    |> count_page_view()
    |> assign_counts()
    |> assign_chat()
    |> assign_shortcuts()
    |> read_only()
    |> subscribe_to_notifications()
    |> subscribe_to_review()
    |> handle_set_theme()
    |> attach_hook(:current_path, :handle_params, fn _params, uri, socket ->
      {:cont, assign(socket, :current_path, URI.parse(uri).path)}
    end)
  end

  # Once the page is live, not for the static render before it.
  defp record_visit(socket) do
    if connected?(socket), do: Visits.seen(socket.assigns.current_user)
    socket
  end

  # Who's on the other end, for the Akismet checks of what this LiveView
  # posts (see Firefly.Moderation.Akismet).
  defp record_client(socket) do
    if connected?(socket) do
      ip = FireflyWeb.ClientIP.from_socket(socket)

      Firefly.Moderation.Akismet.put_client(%{
        ip: if(is_tuple(ip), do: ip |> :inet.ntoa() |> to_string(), else: ip),
        user_agent: get_connect_info(socket, :user_agent)
      })
    end

    socket
  end

  # Each page load or live navigation, but not reconnects (`_mounts` counts
  # those). Crawlers don't always connect: `FireflyWeb.Plugs.Analytics`
  # counts them on the request.
  defp count_page_view(socket) do
    if connected?(socket) and get_connect_params(socket)["_mounts"] in [0, nil] and
         Analytics.enabled?() do
      kind =
        Analytics.kind(socket.assigns.current_user, get_connect_info(socket, :user_agent))

      if kind != "crawler", do: Analytics.page_view(kind)
    end

    socket
  end

  defp read_only(socket) do
    if connected?(socket), do: Backups.subscribe_read_only()

    socket
    |> assign(:read_only, Backups.read_only())
    |> attach_hook(:read_only, :handle_info, fn
      {:read_only, value}, socket -> {:halt, assign(socket, :read_only, value)}
      _other, socket -> {:cont, socket}
    end)
    |> attach_hook(:read_only_events, :handle_event, &refuse_when_read_only/3)
  end

  # Checked when the event comes, not from the assign: another node may
  # have changed it a moment ago.
  defp refuse_when_read_only(_event, _params, socket) do
    if Backups.read_only?() and socket.view != FireflyWeb.StaffLive.Backups do
      {:halt, put_flash(socket, :error, Posting.message(:read_only))}
    else
      {:cont, socket}
    end
  end

  defp assign_counts(socket) do
    user = socket.assigns.current_user

    socket
    |> assign(:notification_count, notification_count(user))
    |> assign(:message_count, Messaging.unread_conversation_count(user))
  end

  defp assign_chat(%{assigns: %{current_user: %{} = user}} = socket),
    do: assign(socket, :chat, Chat.can?(user, :use_chat))

  defp assign_chat(socket), do: assign(socket, :chat, false)

  # Keyboard shortcuts are on unless the member turned them off.
  defp assign_shortcuts(%{assigns: %{current_user: %User{} = user}} = socket),
    do: assign(socket, :shortcuts, user.keyboard_shortcuts)

  defp assign_shortcuts(socket), do: assign(socket, :shortcuts, true)

  defp staff?(%{assigns: %{current_user: %{} = user}}), do: Accounts.admin?(user)
  defp staff?(_socket), do: false

  defp subscribe_to_review(socket) do
    if staff?(socket) do
      if connected?(socket), do: Review.subscribe()

      socket
      |> assign(:review_count, Review.pending_count())
      |> assign(:update_available, Firefly.Upgrades.update_available?())
      |> attach_hook(:review, :handle_info, &handle_review/2)
    else
      assign(socket, :review_count, 0)
    end
  end

  defp handle_review(:review_changed, socket) do
    socket = assign(socket, :review_count, Review.pending_count())

    socket =
      if function_exported?(socket.view, :review_changed, 1),
        do: socket.view.review_changed(socket),
        else: socket

    {:halt, socket}
  end

  defp handle_review(_other, socket), do: {:cont, socket}

  defp notification_count(nil), do: 0
  defp notification_count(user), do: Notifications.unread_notification_count(user)

  # Keeps the notification and message badges live: notify/read broadcasts
  # :notifications_changed on the user's topic (and :account_changed when the
  # account itself changes). Views can export
  # `notifications_changed/1` to react as well (e.g. the notifications page).
  defp subscribe_to_notifications(%{assigns: %{current_user: %{id: user_id}}} = socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Firefly.PubSub, Notifications.notifications_topic(user_id))

      attach_hook(socket, :notifications, :handle_info, &handle_notifications/2)
    else
      socket
    end
  end

  defp subscribe_to_notifications(socket), do: socket

  defp handle_set_theme(%{assigns: %{current_user: %{}}} = socket) do
    attach_hook(socket, :set_theme, :handle_event, fn
      "set_theme", %{"theme" => theme}, socket ->
        case Accounts.update_preferences(socket.assigns.current_user, %{theme: theme}) do
          {:ok, user} -> {:halt, assign(socket, :current_user, user)}
          {:error, _changeset} -> {:halt, socket}
        end

      _event, _params, socket ->
        {:cont, socket}
    end)
  end

  defp handle_set_theme(socket), do: socket

  defp handle_notifications(:notifications_changed, socket) do
    socket = assign_counts(socket)

    socket =
      if function_exported?(socket.view, :notifications_changed, 1),
        do: socket.view.notifications_changed(socket),
        else: socket

    {:halt, socket}
  end

  # The account changed (penalized, deleted): the page reloads, so it mounts
  # again as the account now is (or logged out). See `Session.reload_pages/1`.
  defp handle_notifications(:account_changed, socket) do
    {:halt, redirect(socket, to: socket.assigns[:current_path] || ~p"/")}
  end

  defp handle_notifications(_other, socket), do: {:cont, socket}
end
