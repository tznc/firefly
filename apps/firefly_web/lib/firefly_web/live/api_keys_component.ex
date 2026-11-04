defmodule FireflyWeb.ApiKeysComponent do
  @moduledoc """
  API keys (see `Firefly.Accounts.ApiKeys`): the list, a form to create
  one, and revoking. A new key is shown once, right after it's made.

  `mode`: `:own` (Settings > API keys: the member's own keys) or `:all`
  (`/staff/api-keys`: every key, and creating global keys, which act as
  the user each request names).
  """
  use FireflyWeb, :live_component

  alias Firefly.Accounts.{ApiKey, ApiKeys}

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:new_token, fn -> nil end)
     |> assign_new(:form, fn -> key_form(ApiKeys.change(%{scopes: ["read"]})) end)
     |> load_keys()}
  end

  defp load_keys(%{assigns: %{mode: :all}} = socket),
    do: assign(socket, :keys, ApiKeys.list_all())

  defp load_keys(socket), do: assign(socket, :keys, ApiKeys.list(socket.assigns.current_user))

  defp key_form(changeset), do: to_form(changeset, as: :api_key)

  @impl true
  def handle_event("create", %{"api_key" => params}, socket) do
    %{current_user: user, mode: mode} = socket.assigns
    attrs = attrs(params)

    result =
      if mode == :all and params["global"] == "true",
        do: ApiKeys.create_global(user, attrs),
        else: ApiKeys.create(user, attrs)

    case result do
      {:ok, _key, token} ->
        {:noreply,
         socket
         |> assign(:new_token, token)
         |> assign(:form, key_form(ApiKeys.change(%{scopes: ["read"]})))
         |> load_keys()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, key_form(%{changeset | action: :insert}))}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    with %ApiKey{} = key <- ApiKeys.get(id),
         {:ok, _key} <- ApiKeys.revoke(key, socket.assigns.current_user) do
      {:noreply, socket |> assign(:new_token, nil) |> load_keys()}
    else
      _missing_or_not_theirs -> {:noreply, socket}
    end
  end

  def handle_event("dismiss", _params, socket), do: {:noreply, assign(socket, :new_token, nil)}

  # The form's date (end of that day, UTC) and text lists.
  defp attrs(params) do
    expires_at =
      case params["expires_on"] do
        date when is_binary(date) and date != "" -> date <> "T23:59:59Z"
        _none -> nil
      end

    %{
      "name" => params["name"],
      "scopes" => params["scopes"] || [],
      "allowed_ips" => [params["allowed_ips"] || ""],
      "rate_limit" => params["rate_limit"],
      "expires_at" => expires_at
    }
  end

  defp status(key) do
    cond do
      key.revoked_at -> {"Revoked", "badge-ghost"}
      ApiKey.inactive?(key) -> {"Expired", "badge-ghost"}
      true -> {"Active", "badge-success"}
    end
  end

  defp owner(%ApiKey{user: %{username: username}}), do: "@#{username}"
  defp owner(%ApiKey{created_by: %{username: username}}), do: "Global (by @#{username})"
  defp owner(_key), do: "Global"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :scopes, ApiKeys.scopes())

    ~H"""
    <div id={@id} class="space-y-6">
      <p class="text-sm text-base-content/70">
        Keys let scripts and apps use the
        <a href={~p"/api/v1/docs"} class="link">API</a>
        as {if @mode == :all, do: "a member", else: "you"}, limited to the scopes you pick.
      </p>

      <div :if={@new_token} id="new-api-key" role="status" class="alert alert-success flex-col items-start">
        <p class="font-medium">Copy your new key now: it won't be shown again.</p>
        <code id="new-api-key-token" class="select-all break-all rounded bg-base-100 px-2 py-1 text-base-content">
          {@new_token}
        </code>
        <button type="button" class="btn btn-sm" phx-click="dismiss" phx-target={@myself}>Done</button>
      </div>

      <ul :if={@keys != []} id="api-keys-list" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
        <li :for={key <- @keys} id={"api-key-#{key.id}"} class="flex flex-wrap items-center gap-2 p-3">
          <% {label, class} = status(key) %>
          <span class={["badge badge-sm", class]}>{label}</span>
          <span class="font-medium">{key.name}</span>
          <code class="text-xs text-base-content/70">{key.prefix}…</code>
          <span :if={@mode == :all} class="text-sm text-base-content/70">{owner(key)}</span>
          <span class="text-sm text-base-content/70">{Enum.join(key.scopes, ", ")}</span>
          <span class="ml-auto text-xs text-base-content/70">
            {if key.last_used_at,
              do: "Last used #{Calendar.strftime(key.last_used_at, "%Y-%m-%d %H:%M")} UTC from #{key.last_used_ip}",
              else: "Never used"}
            <span :if={key.expires_at}>· expires {Calendar.strftime(key.expires_at, "%Y-%m-%d")}</span>
          </span>
          <button
            :if={is_nil(key.revoked_at)}
            type="button"
            class="btn btn-ghost btn-xs text-error"
            phx-click="revoke"
            phx-value-id={key.id}
            phx-target={@myself}
            data-confirm="Revoke this key? Anything using it stops working."
          >
            Revoke <span class="sr-only">{key.name}</span>
          </button>
        </li>
      </ul>
      <p :if={@keys == []} id="api-keys-empty" class="text-base-content/70">No API keys yet.</p>

      <.form for={@form} id="api-key-form" phx-submit="create" phx-target={@myself} class="space-y-3 rounded-box border border-base-300 p-4">
        <h2 class="font-semibold">New API key</h2>
        <.input field={@form[:name]} type="text" label="Name" placeholder="What it's for" required />
        <fieldset class="fieldset">
          <legend class="fieldset-legend">Scopes</legend>
          <label :for={{scope, description} <- @scopes} class="label gap-2">
            <input
              type="checkbox"
              name="api_key[scopes][]"
              value={scope}
              class="checkbox checkbox-sm"
              checked={scope in (@form[:scopes].value || [])}
            />
            <span><code>{scope}</code> {description}</span>
          </label>
          <p :for={msg <- Enum.map(@form[:scopes].errors, &translate_error/1)} class="text-error text-sm">{msg}</p>
        </fieldset>
        <.input :if={@mode == :all} id="api-key-global" name="api_key[global]" type="checkbox" value="false" label="Global key: acts as the user named in the Api-Username header (default: you)" />
        <div class="grid gap-3 sm:grid-cols-2">
          <.input name="api_key[expires_on]" type="date" label="Expires (optional)" value="" />
          <.input field={@form[:rate_limit]} type="number" label="Requests per minute (optional)" min="1" />
        </div>
        <.input
          name="api_key[allowed_ips]"
          type="textarea"
          label="Allowed addresses (optional: addresses or CIDR ranges, one per line)"
          value=""
          errors={Enum.map(@form[:allowed_ips].errors, &translate_error/1)}
        />
        <p :for={msg <- Enum.map(@form[:expires_at].errors, &translate_error/1)} class="text-error text-sm">Expiry {msg}</p>
        <div class="flex justify-end">
          <.button variant="primary" phx-disable-with="Creating...">Create key</.button>
        </div>
      </.form>
    </div>
    """
  end
end
