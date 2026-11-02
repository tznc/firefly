defmodule FirestormWeb.Web.SettingsLive.Index do
  @moduledoc """
  The current user's settings, one tab per section:

    * Profile (`/settings/profile`): account fields, the bio, website and
      location shown on their profile, an uploaded avatar (else their
      Gravatar), and profile and user card backgrounds (see
      `FirestormWeb.Uploads.set_profile_image/4`)
    * Interface: the theme
    * Notifications (`/settings/notifications`): email, private messages and
      the levels threads get when you reply or start one
    * Privacy: hiding your profile and presence (see `FirestormWeb.Profiles`),
      your activity from your profile, and yourself from the users directory
    * Muted & ignored (`/settings/users`): the members you mute or ignore
      (see `FirestormWeb.Ignores`), to add or remove
    * Logins (`/settings/logins`): connecting and disconnecting social
      login accounts (see `FirestormWeb.Auth`)
    * Account: downloading your data and deleting your account (both handled
      by `FirestormWeb.Web.AccountController`)
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{Auth, EmailConfirmation, Forums, Ignores, Posting, RateLimit, Uploads}
  alias FirestormWeb.Forums.User

  @sections [
    profile: {"Profile", "hero-user-circle"},
    interface: {"Interface", "hero-swatch"},
    notifications: {"Notifications", "hero-bell"},
    privacy: {"Privacy", "hero-eye-slash"},
    users: {"Muted & ignored", "hero-speaker-x-mark"},
    logins: {"Logins", "hero-key"},
    account: {"Account", "hero-identification"}
  ]

  # Each preferences form only submits its own fields.
  @preference_fields %{
    "interface" => ~w(theme),
    "notifications" =>
      ~w(email_notifications allow_private_messages reply_level new_thread_level),
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
    socket = assign(socket, sections: @sections, image_labels: @image_labels)

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
    |> assign(:form, to_form(User.preferences_changeset(user, %{}), as: :preferences))
    |> assign_ignores()
    |> assign(:identities, Auth.identities(user))
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
         {:ok, user} <- Forums.update_user(old, profile_params(params)) do
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

    case Forums.update_preferences(socket.assigns.current_user, params) do
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

    case Forums.users_by_username([username]) do
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

  def handle_event("remove_ignore", %{"id" => id}, socket) do
    case Forums.get_user(id) do
      nil ->
        {:noreply, assign_ignores(socket)}

      target ->
        {:ok, message} = Ignores.choose(socket.assigns.current_user, target, "normal", nil)
        {:noreply, socket |> assign_ignores() |> put_flash(:info, message)}
    end
  end

  # Only the fields on the form; never e.g. the API token.
  defp profile_params(params), do: Map.take(params, ~w(username name email bio website location))

  defp section_path(:profile), do: ~p"/settings/profile"
  defp section_path(:interface), do: ~p"/settings/interface"
  defp section_path(:notifications), do: ~p"/settings/notifications"
  defp section_path(:privacy), do: ~p"/settings/privacy"
  defp section_path(:users), do: ~p"/settings/users"
  defp section_path(:logins), do: ~p"/settings/logins"
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
          <.button variant="primary" phx-disable-with="Saving...">Save</.button>
        </.form>

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
