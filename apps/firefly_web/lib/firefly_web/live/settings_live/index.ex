defmodule FireflyWeb.SettingsLive.Index do
  @moduledoc """
  The current user's settings, one tab per section:

    * Profile (`/settings/profile`): account fields, the bio, website and
      location shown on their profile, an uploaded avatar (else their
      Gravatar), and profile and user card backgrounds (see
      `Firefly.Uploads.set_profile_image/4`), and a title: one of
      their badges that allows it (see `Firefly.Badges`)
    * Interface: the theme
    * Notifications (`/settings/notifications`): email, private messages,
      the levels threads get when you reply or start one, and how often
      digest emails come (see `Firefly.Notifications.Digests`), and browser push
      notifications for this browser, through the `PushNotifications` hook
      (see `Firefly.Notifications.WebPush`)
    * Privacy: hiding your profile and presence (see `Firefly.Accounts.Profiles`),
      your activity from your profile, and yourself from the users directory
    * Muted & ignored (`/settings/users`): the members you mute or ignore
      (see `Firefly.Accounts.Ignores`), to add or remove
    * Logins (`/settings/logins`): connecting and disconnecting social
      login accounts (see `Firefly.Accounts.Auth`)
    * Security (`/settings/security`): passkeys (see `Firefly.Accounts.Passkeys`),
      and two-factor authentication (see
      `Firefly.Accounts.TwoFactor`): an authenticator app, security keys
      (registered through the `SecurityKeyRegister` hook) and backup codes
    * Account: downloading your data and deleting your account (both handled
      by `FireflyWeb.AccountController`)
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{Accounts, Badges, RateLimit, SiteSettings, Uploads}
  alias Firefly.Accounts.{Auth, EmailConfirmation, Ignores, Passkeys, TwoFactor, WebAuthn}
  alias Firefly.Moderation.Posting
  alias Firefly.Notifications.{Digests, WebPush}

  alias Firefly.Accounts.User

  @sections [
    profile: {"Profile", "hero-user-circle"},
    interface: {"Interface", "hero-swatch"},
    notifications: {"Notifications", "hero-bell"},
    privacy: {"Privacy", "hero-eye-slash"},
    users: {"Muted & ignored", "hero-speaker-x-mark"},
    logins: {"Logins", "hero-key"},
    security: {"Security", "hero-shield-check"},
    account: {"Account", "hero-identification"}
  ]

  # Each preferences form only submits its own fields.
  @preference_fields %{
    "interface" => ~w(theme),
    "notifications" =>
      ~w(email_notifications allow_private_messages reply_level new_thread_level digest_frequency
         push_only_when_away),
    "privacy" => ~w(hide_profile hide_profile_activity hide_from_directory)
  }

  @saved %{
    "interface" => "Interface settings saved.",
    "notifications" => "Notification settings saved.",
    "privacy" => "Privacy settings saved."
  }

  @level_labels %{"watching" => "Watching", "tracking" => "Tracking", "normal" => "Normal"}

  @image_labels %{
    avatar: {"Avatar", "Upload a picture"},
    profile_background: {"Profile background", "Upload a profile background"},
    card_background: {"User card background", "Upload a card background"}
  }

  @impl true
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        sections: @sections,
        image_labels: @image_labels,
        totp_secret: nil,
        key_challenge: nil,
        passkey_challenge: nil,
        new_backup_codes: []
      )

    {:ok,
     Enum.reduce(Uploads.profile_images(), socket, fn image, socket ->
       allow_upload(socket, image,
         accept: ~w(.png .jpg .jpeg .gif .webp),
         max_entries: 1,
         max_file_size: Uploads.max_size(),
         auto_upload: true,
         progress: &image_progress/3
       )
     end)}
  end

  # The profile is public: silenced users can't change its images either.
  defp image_progress(image, %{done?: true} = entry, socket) do
    user = socket.assigns.current_user

    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        case Posting.check(user, :like) do
          :ok -> {:ok, Uploads.set_profile_image(user, image, path, entry.client_name)}
          penalized -> {:ok, penalized}
        end
      end)

    case result do
      {:ok, user} ->
        {label, _} = @image_labels[image]
        {:noreply, socket |> assign_forms(user) |> put_flash(:info, "#{label} updated.")}

      {:error, :rate_limited} ->
        {:noreply, put_flash(socket, :error, RateLimit.message())}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Posting.message(reason))}
    end
  end

  defp image_progress(_image, _entry, socket), do: {:noreply, socket}

  @impl true
  def handle_params(_params, _uri, socket) do
    {title, _icon} = @sections[socket.assigns.live_action]
    {:noreply, socket |> assign(:page_title, "#{title} settings") |> assign_forms()}
  end

  defp assign_forms(socket, user \\ nil) do
    user = user || socket.assigns.current_user

    socket
    |> assign(:current_user, user)
    |> assign(:profile_form, to_form(User.update_changeset(user, %{})))
    |> assign(:titles, Badges.titles(user))
    |> assign(:push_subscriptions, WebPush.subscriptions(user))
    |> assign_new(:push_state, fn -> "unknown" end)
    |> assign(:form, to_form(User.preferences_changeset(user, %{}), as: :preferences))
    |> assign_ignores()
    |> assign(:identities, Auth.identities(user))
    |> assign_security(user)
  end

  defp assign_security(socket, user) do
    assign(socket,
      two_factor?: TwoFactor.enabled?(user),
      totp?: TwoFactor.totp?(user),
      credentials: TwoFactor.credentials(user),
      backup_codes_left: TwoFactor.backup_codes_left(user),
      passkeys: Passkeys.list(user)
    )
  end

  defp assign_ignores(socket) do
    socket
    |> assign(:ignores, Ignores.list(socket.assigns.current_user))
    |> assign(
      :ignore_add_form,
      to_form(%{"username" => "", "level" => "mute", "duration" => "forever"}, as: :ignore)
    )
  end

  @impl true
  def handle_event("validate_profile", %{"user" => params}, socket) do
    changeset = User.update_changeset(socket.assigns.current_user, profile_params(params))
    {:noreply, assign(socket, :profile_form, to_form(changeset, action: :validate))}
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    old = socket.assigns.current_user

    # The profile is public (a markdown bio, a website link): silenced users
    # can't change it.
    with :ok <- Posting.check(old, :like),
         {:ok, user} <- Accounts.update_user(old, profile_params(params)) do
      message =
        if user.email != old.email and not User.confirmed?(user) do
          EmailConfirmation.deliver(user)
          "User updated. We sent a link to #{user.email} to confirm the new address."
        else
          "User updated successfully."
        end

      {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: ~p"/users/#{user}")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Posting.message(reason))}
    end
  end

  def handle_event("set_title", %{"title" => %{"badge_id" => badge_id}}, socket) do
    case Badges.set_title(socket.assigns.current_user, badge_id) do
      {:ok, user} ->
        {:noreply, socket |> assign_forms(user) |> put_flash(:info, "Title updated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Badges.message(reason))}
    end
  end

  def handle_event("push_state", %{"state" => state}, socket)
      when state in ~w(on off denied unsupported),
      do: {:noreply, assign(socket, :push_state, state)}

  def handle_event("push_subscribe", %{"subscription" => subscription} = params, socket) do
    user = socket.assigns.current_user

    case WebPush.subscribe(user, subscription, params["user_agent"]) do
      {:ok, _subscription} ->
        {:noreply,
         socket
         |> assign(:push_subscriptions, WebPush.subscriptions(user))
         |> put_flash(:info, "Push notifications are on for this browser.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "This browser's push subscription didn't work.")}
    end
  end

  def handle_event("push_unsubscribe", params, socket) do
    user = socket.assigns.current_user

    target =
      case params do
        %{"id" => id} -> {:id, id}
        %{"endpoint" => endpoint} -> endpoint
      end

    WebPush.unsubscribe(user, target)
    {:noreply, assign(socket, :push_subscriptions, WebPush.subscriptions(user))}
  end

  def handle_event("validate_image", _params, socket), do: {:noreply, socket}

  def handle_event("remove_image", %{"image" => name}, socket) do
    case Enum.find(Uploads.profile_images(), &(to_string(&1) == name)) do
      nil ->
        {:noreply, socket}

      image ->
        {:ok, user} = Uploads.remove_profile_image(socket.assigns.current_user, image)
        {label, _} = @image_labels[image]
        {:noreply, socket |> assign_forms(user) |> put_flash(:info, "#{label} removed.")}
    end
  end

  def handle_event("save_" <> section, %{"preferences" => params}, socket)
      when is_map_key(@preference_fields, section) do
    params = Map.take(params, @preference_fields[section])

    case Accounts.update_preferences(socket.assigns.current_user, params) do
      {:ok, user} ->
        {:noreply,
         socket
         |> assign_forms(user)
         |> push_event("set-theme", %{theme: user.theme})
         |> put_flash(:info, @saved[section])}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :preferences))}
    end
  end

  def handle_event("add_ignore", %{"ignore" => params}, socket) do
    user = socket.assigns.current_user
    username = params |> Map.get("username", "") |> String.trim() |> String.trim_leading("@")

    case Accounts.users_by_username([username]) do
      %{^username => target} ->
        case Ignores.choose(user, target, params["level"], params["duration"]) do
          {:ok, message} -> {:noreply, socket |> assign_ignores() |> put_flash(:info, message)}
          {:error, message} -> {:noreply, put_flash(socket, :error, message)}
        end

      _none ->
        {:noreply, put_flash(socket, :error, "No such user: @#{username}")}
    end
  end

  def handle_event("disconnect", %{"provider" => provider}, socket) do
    case Auth.disconnect(socket.assigns.current_user, provider) do
      :ok ->
        {:noreply,
         socket
         |> assign_forms()
         |> put_flash(:info, "#{Auth.label(provider)} account disconnected.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("start_totp", _params, socket),
    do: {:noreply, assign(socket, :totp_secret, TwoFactor.new_secret())}

  def handle_event("cancel_totp", _params, socket),
    do: {:noreply, assign(socket, :totp_secret, nil)}

  def handle_event("enable_totp", %{"code" => code}, %{assigns: %{totp_secret: secret}} = socket)
      when is_binary(secret) do
    case TwoFactor.enable_totp(socket.assigns.current_user, secret, code) do
      {:ok, codes} ->
        {:noreply,
         socket
         |> assign(totp_secret: nil, new_backup_codes: codes)
         |> assign_forms()
         |> put_flash(:info, "Two-factor authentication is on.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, TwoFactor.message(reason))}
    end
  end

  def handle_event("disable_totp", %{"confirmation" => confirmation}, socket) do
    security_change(
      socket,
      TwoFactor.disable_totp(socket.assigns.current_user, confirmation),
      "Authenticator app removed."
    )
  end

  def handle_event("regenerate_backup_codes", _params, socket) do
    case TwoFactor.regenerate_backup_codes(socket.assigns.current_user) do
      {:ok, codes} ->
        {:noreply,
         socket
         |> assign(:new_backup_codes, codes)
         |> assign_forms()
         |> put_flash(:info, "New backup codes made: the old ones no longer work.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, TwoFactor.message(reason))}
    end
  end

  def handle_event("security_key_options", _params, socket) do
    {challenge, options} =
      WebAuthn.registration(socket.assigns.current_user, socket.assigns.credentials)

    {:reply, %{options: options}, assign(socket, :key_challenge, challenge)}
  end

  def handle_event("security_key_register", params, %{assigns: %{key_challenge: %{}}} = socket) do
    %{current_user: user, key_challenge: challenge} = socket.assigns
    socket = assign(socket, :key_challenge, nil)

    with {:ok, attrs} <- WebAuthn.register(challenge, params),
         {:ok, _credential, codes} <- TwoFactor.add_credential(user, attrs, params["name"]) do
      {:noreply,
       socket
       |> assign(:new_backup_codes, codes)
       |> assign_forms()
       |> put_flash(:info, "Security key added.")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That security key couldn't be added.")}
    end
  end

  def handle_event("security_key_register", _params, socket), do: {:noreply, socket}

  def handle_event("security_key_error", _params, socket),
    do: {:noreply, put_flash(socket, :error, "The browser didn't create a security key.")}

  def handle_event("passkey_options", _params, socket) do
    {challenge, options} = Passkeys.registration(socket.assigns.current_user)
    {:reply, %{options: options}, assign(socket, :passkey_challenge, challenge)}
  end

  def handle_event("passkey_register", params, %{assigns: %{passkey_challenge: %{}}} = socket) do
    %{current_user: user, passkey_challenge: challenge} = socket.assigns
    socket = assign(socket, :passkey_challenge, nil)

    with true <- Passkeys.enabled?() || {:error, :disabled},
         {:ok, attrs} <- WebAuthn.register(challenge, params),
         {:ok, _passkey} <- Passkeys.add(user, attrs, params["name"]) do
      {:noreply, socket |> assign_forms() |> put_flash(:info, "Passkey added.")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That passkey couldn't be added.")}
    end
  end

  def handle_event("passkey_register", _params, socket), do: {:noreply, socket}

  def handle_event("rename_passkey", %{"key_id" => id, "name" => name}, socket) do
    case Passkeys.rename(socket.assigns.current_user, id, name) do
      {:ok, _passkey} ->
        {:noreply, socket |> assign_forms() |> put_flash(:info, "Renamed.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Passkeys.message(reason))}
    end
  end

  def handle_event("delete_passkey", %{"key_id" => id}, socket) do
    case Passkeys.delete(socket.assigns.current_user, id) do
      :ok -> {:noreply, socket |> assign_forms() |> put_flash(:info, "Passkey removed.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, Passkeys.message(reason))}
    end
  end

  def handle_event("rename_key", %{"key_id" => id, "name" => name}, socket) do
    case TwoFactor.rename_credential(socket.assigns.current_user, id, name) do
      {:ok, _credential} ->
        {:noreply, socket |> assign_forms() |> put_flash(:info, "Renamed.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_message(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, TwoFactor.message(reason))}
    end
  end

  def handle_event("delete_key", %{"key_id" => id, "confirmation" => confirmation}, socket) do
    user = socket.assigns.current_user

    security_change(
      socket,
      TwoFactor.delete_credential(user, id, confirmation),
      "Security key removed."
    )
  end

  def handle_event("remove_ignore", %{"id" => id}, socket) do
    case Accounts.get_user(id) do
      nil ->
        {:noreply, assign_ignores(socket)}

      target ->
        {:ok, message} = Ignores.choose(socket.assigns.current_user, target, "normal", nil)
        {:noreply, socket |> assign_ignores() |> put_flash(:info, message)}
    end
  end

  defp security_change(socket, :ok, message),
    do: {:noreply, socket |> assign_forms() |> put_flash(:info, message)}

  defp security_change(socket, {:error, reason}, _message),
    do: {:noreply, put_flash(socket, :error, TwoFactor.message(reason))}

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&FireflyWeb.CoreComponents.translate_error/1)
    |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)
    |> String.capitalize()
  end

  # Only the fields on the form; never e.g. the API token.
  defp profile_params(params), do: Map.take(params, ~w(username name email bio website location))

  defp section_path(:profile), do: ~p"/settings/profile"
  defp section_path(:interface), do: ~p"/settings/interface"
  defp section_path(:notifications), do: ~p"/settings/notifications"
  defp section_path(:privacy), do: ~p"/settings/privacy"
  defp section_path(:users), do: ~p"/settings/users"
  defp section_path(:logins), do: ~p"/settings/logins"
  defp section_path(:security), do: ~p"/settings/security"
  defp section_path(:account), do: ~p"/settings/account"

  attr :image, :atom, required: true
  attr :labels, :any, required: true
  attr :upload, :any, required: true
  attr :user, :any, required: true

  # Uploading or removing one of the user's profile images.
  defp image_form(assigns) do
    assigns =
      assign(assigns,
        set?: Map.fetch!(assigns.user, image_field(assigns.image)) != nil,
        preview:
          if(assigns.image != :avatar, do: User.background_url(assigns.user, assigns.image))
      )

    ~H"""
    <.form
      for={%{}}
      id={"#{@image}-form"}
      phx-change="validate_image"
      class="space-y-2 rounded-box border border-base-300 p-3"
    >
      <p class="text-sm font-semibold">{elem(@labels, 0)}</p>
      <.avatar :if={@image == :avatar} user={@user} size="size-14" />
      <div
        :if={@image != :avatar}
        class="h-14 rounded bg-base-200 bg-cover bg-center"
        style={@preview && "background-image: url('#{@preview}')"}
      >
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <label class="btn btn-sm" for={@upload.ref}>
          <.icon name="hero-photo" class="size-4" /> {elem(@labels, 1)}
        </label>
        <.live_file_input upload={@upload} class="hidden" aria-label={elem(@labels, 0)} />
        <button
          :if={@set?}
          type="button"
          class="btn btn-ghost btn-sm"
          phx-click="remove_image"
          phx-value-image={@image}
          aria-label={"Remove #{elem(@labels, 0)}"}
        >
          Remove
        </button>
      </div>
      <p :if={@image == :avatar and not @set?} class="text-xs text-base-content/70">
        Or set it at <a href="https://gravatar.com" class="link">gravatar.com</a>
      </p>
      <span :for={entry <- @upload.entries} class="flex items-center gap-2 text-sm">
        <progress class="progress progress-primary w-24" value={entry.progress} max="100" />
        <span :for={err <- upload_errors(@upload, entry)} class="text-error">
          {avatar_error(err)}
        </span>
      </span>
    </.form>
    """
  end

  defp identity_name(%{info: info}) do
    case info["nickname"] || info["email"] || info["name"] do
      nil -> ""
      name -> " as #{name}"
    end
  end

  defp confirmation_label(%User{password_hash: hash}) when is_binary(hash),
    do: "Your password or a current code"

  defp confirmation_label(_user), do: "A current code"

  defp image_field(:avatar), do: :avatar_upload_id
  defp image_field(:profile_background), do: :profile_background_upload_id
  defp image_field(:card_background), do: :card_background_upload_id

  defp avatar_error(:too_large), do: "That file is too large."
  defp avatar_error(:not_accepted), do: "Pick a PNG, JPEG, GIF or WebP image."
  defp avatar_error(other), do: "Upload error: #{other}"

  defp level_options(levels), do: Enum.map(levels, &{@level_labels[&1], &1})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Settings" />

      <div role="tablist" class="tabs tabs-border" id="settings-tabs">
        <.link
          :for={{action, {title, icon}} <- @sections}
          patch={section_path(action)}
          role="tab"
          class={["tab gap-2", @live_action == action && "tab-active"]}
          aria-selected={to_string(@live_action == action)}
        >
          <.icon name={icon} class="size-4" /> {title}
        </.link>
      </div>

      <div :if={@live_action == :profile} class="grid gap-4 py-2 sm:grid-cols-3">
        <.image_form
          :for={image <- Uploads.profile_images()}
          image={image}
          labels={@image_labels[image]}
          upload={@uploads[image]}
          user={@current_user}
        />
      </div>

      <.form
        :if={@live_action == :profile}
        for={@profile_form}
        id="profile-form"
        phx-change="validate_profile"
        phx-submit="save_profile"
        class="space-y-2"
      >
        <.input field={@profile_form[:username]} type="text" label="Username" />
        <p class="-mt-1 text-xs text-base-content/60">People can mention you as @username</p>
        <.input field={@profile_form[:name]} type="text" label="Name" />
        <p class="-mt-1 text-xs text-base-content/60">Your full name (optional)</p>
        <.input field={@profile_form[:email]} type="email" label="Email" />
        <p class="-mt-1 text-xs text-base-content/60">Never shown to the public</p>
        <.input field={@profile_form[:bio]} type="textarea" label="About me" rows="4" />
        <p class="-mt-1 text-xs text-base-content/60">A few lines about you. Markdown works.</p>
        <.input
          field={@profile_form[:website]}
          type="url"
          label="Website"
          placeholder="https://example.com"
        />
        <.input field={@profile_form[:location]} type="text" label="Location" />
        <div class="flex justify-end">
          <.button variant="primary" phx-disable-with="Saving...">Save</.button>
        </div>
      </.form>

      <.form
        :if={@live_action == :profile && @titles != []}
        for={%{"badge_id" => @current_user.title_badge_id}}
        as={:title}
        id="title-form"
        phx-submit="set_title"
        class="flex items-end gap-2"
      >
        <.input
          name="title[badge_id]"
          value={@current_user.title_badge_id}
          type="select"
          label="Title"
          prompt="None"
          options={Enum.map(@titles, &{&1.name, &1.id})}
        />
        <.button phx-disable-with="Saving...">Set title</.button>
      </.form>

      <.form
        :if={@live_action == :interface}
        for={@form}
        id="interface-form"
        phx-submit="save_interface"
        class="space-y-4"
      >
        <.input
          field={@form[:theme]}
          type="select"
          label="Theme"
          options={[{"Follow my system", "system"}, {"Light", "light"}, {"Dark", "dark"}]}
        />
        <p class="-mt-2 text-xs text-base-content/60">
          Applies wherever you're logged in. The toggle in the top bar changes it too.
        </p>
        <.button variant="primary" phx-disable-with="Saving...">Save</.button>
      </.form>

      <div :if={@live_action == :notifications} class="space-y-6">
        <.form for={@form} id="preferences-form" phx-submit="save_notifications" class="space-y-4">
            <.input
            field={@form[:email_notifications]}
            type="checkbox"
            label="Email me about new posts in threads and categories I'm watching, private messages, and when I'm mentioned"
          />
          <.input
            field={@form[:allow_private_messages]}
            type="checkbox"
            label="Allow other members to send me private messages"
          />
          <.input
            field={@form[:new_thread_level]}
            type="select"
            label="When I start a thread"
            options={level_options(User.new_thread_levels())}
          />
          <.input
            field={@form[:reply_level]}
            type="select"
            label="When I reply to a thread"
            options={level_options(User.reply_levels())}
          />
          <.input
            :if={SiteSettings.get("digests_enabled")}
            field={@form[:digest_frequency]}
            type="select"
            label="When I haven't visited in a while, email me a summary"
            prompt={"Site default (#{Digests.label(SiteSettings.get("default_digest_frequency"))})"}
            options={Digests.frequency_options()}
          />
          <.input
            :if={WebPush.enabled?()}
            field={@form[:push_only_when_away]}
            type="checkbox"
            label="Send browser push notifications only when I'm away from the site"
          />
          <.button variant="primary" phx-disable-with="Saving...">Save</.button>
        </.form>

        <section
          :if={WebPush.enabled?()}
          id="push-notifications"
          phx-hook="PushNotifications"
          data-public-key={WebPush.public_key()}
          class="card border border-base-300 bg-base-100"
        >
          <div class="card-body gap-2">
            <h2 class="card-title text-base">Browser push notifications</h2>
            <p :if={@push_state == "unsupported"} class="text-sm">
              This browser doesn't support push notifications.
            </p>
            <p :if={@push_state == "denied"} class="text-sm">
              Notifications are blocked for this site in your browser's settings.
            </p>
            <div :if={@push_state in ~w(on off)} class="flex items-center gap-2">
              <span id="push-state" class="text-sm">
                {if @push_state == "on", do: "On for this browser.", else: "Off for this browser."}
              </span>
              <button :if={@push_state == "off"} type="button" data-push="on" class="btn btn-primary btn-sm">
                Turn on
              </button>
              <button :if={@push_state == "on"} type="button" data-push="off" class="btn btn-sm">
                Turn off
              </button>
            </div>
            <ul :if={@push_subscriptions != []} id="push-subscriptions" class="text-sm">
              <li :for={s <- @push_subscriptions} class="flex items-center gap-2">
                <span class="flex-1 truncate">{s.user_agent || URI.parse(s.endpoint).host}</span>
                <span class="text-base-content/60">since {short_date(s.inserted_at)}</span>
                <button
                  type="button"
                  phx-click="push_unsubscribe"
                  phx-value-id={s.id}
                  class="btn btn-ghost btn-xs"
                  aria-label="Remove this browser"
                >
                  Remove
                </button>
              </li>
            </ul>
          </div>
        </section>

        <div class="prose prose-sm max-w-none text-base-content/80">
          <h2 class="text-base">Notification levels</h2>
          <p>Set a level from the menu on any thread, category or tag:</p>
          <ul>
            <li>
              <strong>Watching</strong>: notified of every new post, and emailed (once per thread until you've read it).
            </li>
            <li><strong>Tracking</strong>: notified of every new post, no email.</li>
            <li><strong>Normal</strong>: not notified, unless someone @mentions you.</li>
            <li>
              <strong>Muted</strong>: not notified, even of mentions, and hidden from Latest, New and Unread.
            </li>
          </ul>
          <p>
            Threads you start or reply to get the levels chosen above, unless you've set one on the thread or its category or tags already give a more attentive one. Category and tag levels apply to their threads unless you set one on the thread: a muted category or tag hides the thread, otherwise the most attentive level wins.
          </p>
        </div>
      </div>

      <.form
        :if={@live_action == :privacy}
        for={@form}
        id="privacy-form"
        phx-submit="save_privacy"
        class="space-y-4"
      >
        <.input
          field={@form[:hide_profile]}
          type="checkbox"
          label="Hide my public profile and presence: others only see my username and avatar, not my profile, stats, activity or when I was last seen (admins still do)"
        />
        <.input
          field={@form[:hide_profile_activity]}
          type="checkbox"
          label="Hide my posts and activity from my profile (admins still see them)"
        />
        <.input
          field={@form[:hide_from_directory]}
          type="checkbox"
          label="Leave me out of the users directory"
        />
        <p class="text-xs text-base-content/60">
          Your posts stay visible in their threads and in search.
        </p>
        <.button variant="primary" phx-disable-with="Saving...">Save</.button>
      </.form>
      <div :if={@live_action == :users} class="space-y-6">
        <p class="text-sm text-base-content/70">
          Muting someone stops notifications and private messages from them. Ignoring them also collapses their posts (you can still open each one) and hides the threads and conversations they start. They aren't told. Staff can't be muted or ignored.
        </p>
        <ul id="ignores" class="list rounded-box border border-base-300 bg-base-100">
          <li :if={@ignores == []} class="list-row text-base-content/60">
            You don't mute or ignore anyone.
          </li>
          <li :for={ignore <- @ignores} id={"ignore-#{ignore.ignored_user_id}"} class="list-row items-center">
            <.avatar user={ignore.ignored_user} size="size-8" />
            <div class="list-col-grow">
              <.link navigate={~p"/users/#{ignore.ignored_user}"} class="font-medium hover:text-primary">
                @{ignore.ignored_user.username}
              </.link>
              <span class="badge badge-sm ml-2">
                {if ignore.level == "ignore", do: "Ignored", else: "Muted"}
              </span>
              <span :if={ignore.expires_at} class="text-xs text-base-content/60">
                until {short_date(ignore.expires_at)}
              </span>
            </div>
            <button
              type="button"
              phx-click="remove_ignore"
              phx-value-id={ignore.ignored_user_id}
              class="btn btn-ghost btn-sm"
              aria-label={"Stop muting or ignoring @#{ignore.ignored_user.username}"}
            >
              Remove
            </button>
          </li>
        </ul>
        <.form
          for={@ignore_add_form}
          id="add-ignore-form"
          phx-submit="add_ignore"
          class="flex flex-wrap items-end gap-2"
        >
          <div class="w-48">
            <.input field={@ignore_add_form[:username]} type="text" label="Username" />
          </div>
          <div class="w-36">
            <.input
              field={@ignore_add_form[:level]}
              type="select"
              label="Level"
              options={[{"Mute", "mute"}, {"Ignore", "ignore"}]}
            />
          </div>
          <div class="w-36">
            <.input
              field={@ignore_add_form[:duration]}
              type="select"
              label="Ignore for"
              options={Ignores.durations()}
            />
          </div>
          <button class="btn btn-sm mb-2">Add</button>
        </.form>
      </div>
      <div :if={@live_action == :logins} class="space-y-4">
        <p class="text-sm text-base-content/70">
          Log in with any account connected here{if @current_user.password_hash,
            do: ", or with your username and password",
            else: ""}.
        </p>
        <ul id="logins" class="list rounded-box border border-base-300 bg-base-100">
          <li
            :for={provider <- Auth.providers()}
            :if={Auth.enabled?(provider) or Map.has_key?(@identities, to_string(provider))}
            id={"login-#{provider}"}
            class="list-row items-center"
          >
            <div class="list-col-grow">
              <p class="font-medium">{Auth.label(provider)}</p>
              <p :if={identity = @identities[to_string(provider)]} class="text-xs text-base-content/60">
                Connected{identity_name(identity)}
              </p>
            </div>
            <button
              :if={Map.has_key?(@identities, to_string(provider))}
              type="button"
              phx-click="disconnect"
              phx-value-provider={provider}
              data-confirm={"Disconnect your #{Auth.label(provider)} account?"}
              class="btn btn-ghost btn-sm"
              aria-label={"Disconnect #{Auth.label(provider)}"}
            >
              Disconnect
            </button>
            <a
              :if={!Map.has_key?(@identities, to_string(provider))}
              href={~p"/auth/#{provider}"}
              class="btn btn-sm"
              aria-label={"Connect #{Auth.label(provider)}"}
            >
              Connect
            </a>
          </li>
        </ul>
      </div>
      <div :if={@live_action == :security} class="space-y-6" id="security">
        <p class="text-sm text-base-content/70">
          Two-factor authentication is <strong>{if @two_factor?, do: "on", else: "off"}</strong>.
          With it on, logging in also asks for a code from your authenticator app or one of your security keys.
        </p>

        <section :if={Passkeys.enabled?()} class="card border border-base-300 bg-base-100" id="passkeys">
          <div class="card-body gap-3">
            <h2 class="card-title text-base">Passkeys</h2>
            <p class="text-sm text-base-content/70">
              Log in with your fingerprint, face or device PIN instead of a password. A passkey login needs no second factor.
            </p>
            <ul class="list rounded-box border border-base-300">
              <li :if={@passkeys == []} class="list-row text-base-content/60">No passkeys.</li>
              <li :for={passkey <- @passkeys} id={"passkey-#{passkey.id}"} class="list-row items-end">
                <.form
                  for={%{}}
                  id={"rename-passkey-#{passkey.id}"}
                  phx-submit="rename_passkey"
                  class="list-col-grow flex items-end gap-2"
                >
                  <input type="hidden" name="key_id" value={passkey.id} />
                  <.input name="name" value={passkey.name} label="Name" />
                  <button class="btn btn-ghost btn-sm mb-2">Rename</button>
                </.form>
                <button
                  type="button"
                  phx-click="delete_passkey"
                  phx-value-key_id={passkey.id}
                  data-confirm={"Remove the passkey #{passkey.name}?"}
                  class="btn btn-ghost btn-sm mb-2"
                  aria-label={"Remove passkey #{passkey.name}"}
                >
                  Remove
                </button>
              </li>
            </ul>
            <div class="flex items-end gap-2">
              <.input id="new-passkey-name" name="new_passkey_name" value="" label="New passkey's name" />
              <button
                type="button"
                id="add-passkey"
                phx-hook="SecurityKeyRegister"
                data-options-event="passkey_options"
                data-register-event="passkey_register"
                data-name-input="new-passkey-name"
                class="btn btn-sm mb-2"
              >
                <.icon name="hero-finger-print" class="size-4" /> Add a passkey
              </button>
            </div>
          </div>
        </section>

        <section class="card border border-base-300 bg-base-100" id="authenticator-app">
          <div class="card-body gap-3">
            <h2 class="card-title text-base">Authenticator app</h2>
            <div :if={!@totp? and is_nil(@totp_secret)}>
              <button type="button" phx-click="start_totp" class="btn btn-sm">
                Set up an authenticator app
              </button>
            </div>
            <div :if={@totp_secret} class="space-y-3">
              <p class="text-sm">
                Scan this with your authenticator app (or type the key), then enter the code it shows.
              </p>
              <div id="totp-qr" class="w-48 rounded bg-white p-2">
                {Phoenix.HTML.raw(TwoFactor.qr_svg(TwoFactor.totp_uri(@current_user, @totp_secret)))}
              </div>
              <p class="font-mono text-sm" id="totp-secret">{TwoFactor.display_secret(@totp_secret)}</p>
              <.form for={%{}} id="enable-totp-form" phx-submit="enable_totp" class="flex items-end gap-2">
                <.input name="code" value="" label="Code" autocomplete="one-time-code" inputmode="numeric" />
                <button class="btn btn-primary btn-sm mb-2">Turn on</button>
                <button type="button" phx-click="cancel_totp" class="btn btn-ghost btn-sm mb-2">Cancel</button>
              </.form>
            </div>
            <.form
              :if={@totp?}
              for={%{}}
              id="disable-totp-form"
              phx-submit="disable_totp"
              class="flex flex-wrap items-end gap-2"
            >
              <.input
                name="confirmation"
                value=""
                type="password"
                label={confirmation_label(@current_user)}
                autocomplete="off"
              />
              <button class="btn btn-sm mb-2">Remove authenticator app</button>
            </.form>
          </div>
        </section>

        <section class="card border border-base-300 bg-base-100" id="security-keys">
          <div class="card-body gap-3">
            <h2 class="card-title text-base">Security keys</h2>
            <ul class="list rounded-box border border-base-300">
              <li :if={@credentials == []} class="list-row text-base-content/60">No security keys.</li>
              <li :for={key <- @credentials} id={"key-#{key.id}"} class="list-row items-end">
                <.form
                  for={%{}}
                  id={"rename-key-#{key.id}"}
                  phx-submit="rename_key"
                  class="list-col-grow flex items-end gap-2"
                >
                  <input type="hidden" name="key_id" value={key.id} />
                  <.input name="name" value={key.name} label="Name" />
                  <button class="btn btn-ghost btn-sm mb-2">Rename</button>
                </.form>
                <.form for={%{}} id={"delete-key-#{key.id}"} phx-submit="delete_key" class="flex items-end gap-2">
                  <input type="hidden" name="key_id" value={key.id} />
                  <.input
                    name="confirmation"
                    value=""
                    type="password"
                    label={confirmation_label(@current_user)}
                    autocomplete="off"
                  />
                  <button class="btn btn-ghost btn-sm mb-2" aria-label={"Remove #{key.name}"}>Remove</button>
                </.form>
              </li>
            </ul>
            <div class="flex items-end gap-2">
              <.input id="new-key-name" name="new_key_name" value="" label="New key's name" />
              <button
                type="button"
                id="add-security-key"
                phx-hook="SecurityKeyRegister"
                data-name-input="new-key-name"
                class="btn btn-sm mb-2"
              >
                <.icon name="hero-key" class="size-4" /> Add a security key
              </button>
            </div>
          </div>
        </section>

        <section :if={@two_factor? or @new_backup_codes != []} class="card border border-base-300 bg-base-100" id="backup-codes">
          <div class="card-body gap-3">
            <h2 class="card-title text-base">Backup codes</h2>
            <div :if={@new_backup_codes != []} class="alert alert-warning block">
              <p class="mb-2 text-sm">
                Save these somewhere safe now: they won't be shown again. Each works once, in place of a code.
              </p>
              <ul id="new-backup-codes" class="grid grid-cols-2 gap-1 font-mono">
                <li :for={code <- @new_backup_codes}>{code}</li>
              </ul>
            </div>
            <p class="text-sm" id="backup-codes-left">{@backup_codes_left} unused backup codes.</p>
            <div>
              <button
                type="button"
                phx-click="regenerate_backup_codes"
                data-confirm="Make new backup codes? The old ones will stop working."
                class="btn btn-sm"
              >
                Generate new backup codes
              </button>
            </div>
          </div>
        </section>
      </div>
      <div :if={@live_action == :account} class="space-y-6">
        <section class="card border border-base-300 bg-base-100">
          <div class="card-body">
            <h2 class="card-title text-base">Download your data</h2>
            <p class="text-sm text-base-content/70">
              A JSON file with your profile, settings, posts and their edits, threads, likes, notifications, private messages you sent and the conversations you're in.
            </p>
            <div class="card-actions">
              <a href={~p"/settings/export"} id="export-data" class="btn btn-sm" download>
                <.icon name="hero-arrow-down-tray" class="size-4" /> Download my data
              </a>
            </div>
          </div>
        </section>

        <section class="card border border-error/40 bg-base-100">
          <div class="card-body">
            <h2 class="card-title text-base text-error">Delete your account</h2>
            <p class="text-sm text-base-content/70">
              Your profile, email, settings, notifications, likes and read positions are deleted, and you're logged out everywhere. Your posts, threads and private messages stay, credited to an anonymous deleted user. This can't be undone.
            </p>
            <.form
              for={%{}}
              as={:account}
              id="delete-account-form"
              action={~p"/settings/account"}
              method="delete"
              class="space-y-2"
            >
              <.input
                :if={@current_user.password_hash}
                name="confirmation"
                type="password"
                value=""
                label="Your password"
                autocomplete="current-password"
              />
              <.input
                :if={!@current_user.password_hash}
                name="confirmation"
                type="text"
                value=""
                label={"Type your username (#{@current_user.username}) to confirm"}
                autocomplete="off"
              />
              <button
                class="btn btn-error btn-sm"
                data-confirm="Delete your account for good?"
              >
                Delete my account
              </button>
            </.form>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
