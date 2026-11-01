defmodule FirestormWeb.Web.SettingsLive.Index do
  @moduledoc """
  The current user's settings, one tab per section:

    * Profile (`/settings/profile`): account fields and the bio, website and
      location shown on their profile
    * Interface: the theme
    * Notifications (`/settings/notifications`): email, private messages and
      the levels threads get when you reply or start one
    * Privacy: hiding your activity from your profile, and yourself from the
      users directory
    * Account: downloading your data and deleting your account (both handled
      by `FirestormWeb.Web.AccountController`)
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.{EmailConfirmation, Forums}
  alias FirestormWeb.Forums.User

  @sections [
    profile: {"Profile", "hero-user-circle"},
    interface: {"Interface", "hero-swatch"},
    notifications: {"Notifications", "hero-bell"},
    privacy: {"Privacy", "hero-eye-slash"},
    account: {"Account", "hero-identification"}
  ]

  # Each preferences form only submits its own fields.
  @preference_fields %{
    "interface" => ~w(theme),
    "notifications" =>
      ~w(email_notifications allow_private_messages reply_level new_thread_level),
    "privacy" => ~w(hide_profile_activity hide_from_directory)
  }

  @saved %{
    "interface" => "Interface settings saved.",
    "notifications" => "Notification settings saved.",
    "privacy" => "Privacy settings saved."
  }

  @level_labels %{"watching" => "Watching", "tracking" => "Tracking", "normal" => "Normal"}

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :sections, @sections)}

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
  end

  @impl true
  def handle_event("validate_profile", %{"user" => params}, socket) do
    changeset = User.update_changeset(socket.assigns.current_user, profile_params(params))
    {:noreply, assign(socket, :profile_form, to_form(changeset, action: :validate))}
  end

  def handle_event("save_profile", %{"user" => params}, socket) do
    old = socket.assigns.current_user

    case Forums.update_user(old, profile_params(params)) do
      {:ok, user} ->
        message =
          if user.email != old.email and not User.confirmed?(user) do
            EmailConfirmation.deliver(user)
            "User updated. We sent a link to #{user.email} to confirm the new address."
          else
            "User updated successfully."
          end

        {:noreply, socket |> put_flash(:info, message) |> push_navigate(to: ~p"/users/#{user}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :profile_form, to_form(changeset))}
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

  # Only the fields on the form; never e.g. the API token.
  defp profile_params(params), do: Map.take(params, ~w(username name email bio website location))

  defp section_path(:profile), do: ~p"/settings/profile"
  defp section_path(:interface), do: ~p"/settings/interface"
  defp section_path(:notifications), do: ~p"/settings/notifications"
  defp section_path(:privacy), do: ~p"/settings/privacy"
  defp section_path(:account), do: ~p"/settings/account"

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
        <div class="flex items-center gap-3 py-2">
          <.avatar user={@current_user} size="size-14" />
          <p class="text-sm text-base-content/70">
            Your avatar is set at <a href="https://gravatar.com" class="link">gravatar.com</a>
          </p>
        </div>
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
            Threads you start or reply to get the levels chosen above, unless you've set one on the thread. Category and tag levels apply to their threads unless you set one on the thread: a muted category or tag hides the thread, otherwise the most attentive level wins.
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
