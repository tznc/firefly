defmodule FireflyWeb.StaffLive.AI do
  @moduledoc """
  AI (admins only; see `Firefly.AI`): turning AI on and off, the model
  providers (add, edit, delete, test the connection), which provider serves
  each feature and who may use it, the built-in prompts, and the usage log.
  Quotas and prompt overrides are site settings (the AI sections at
  `/staff/settings`).
  """
  use FireflyWeb, :live_view

  on_mount({FireflyWeb.UserAuth, :require_user})

  alias Firefly.{AI, SiteSettings}
  alias Firefly.AI.{ProviderConfig, Prompts, Usage}

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :manage_ai) do
      {:ok,
       socket
       |> assign(:page_title, "AI")
       |> assign(:tests, %{})
       |> edit(nil)
       |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  defp load(socket) do
    providers = AI.list_providers()

    socket
    |> assign(:enabled, AI.enabled?())
    |> assign(:providers, providers)
    |> assign(:provider_options, Enum.map(providers, &{&1.name, &1.id}))
    |> assign(:settings, AI.feature_settings())
    |> assign(:usage, Usage.recent())
  end

  defp edit(socket, provider) do
    socket
    |> assign(:editing, provider)
    |> assign(:form, to_form(AI.change_provider(provider || %ProviderConfig{})))
  end

  @impl true
  def handle_event("toggle_ai", _params, socket) do
    value = to_string(not AI.enabled?())
    {:ok, _} = SiteSettings.update(%{"ai_enabled" => value}, socket.assigns.current_user)
    {:noreply, load(socket)}
  end

  def handle_event("edit", %{"id" => id}, socket) do
    {:noreply, edit(socket, AI.get_provider(id))}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, edit(socket, nil)}

  def handle_event("save_provider", %{"provider_config" => params}, socket) do
    admin = socket.assigns.current_user

    result =
      case socket.assigns.editing do
        nil -> AI.create_provider(params, admin)
        provider -> AI.update_provider(provider, params, admin)
      end

    case result do
      {:ok, provider} ->
        {:noreply,
         socket
         |> put_flash(:info, "Provider #{provider.name} saved.")
         |> edit(nil)
         |> load()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case AI.get_provider(id) do
      nil ->
        {:noreply, socket}

      provider ->
        :ok = AI.delete_provider(provider, socket.assigns.current_user)

        {:noreply,
         socket
         |> put_flash(:info, "Provider #{provider.name} deleted.")
         |> edit(nil)
         |> load()}
    end
  end

  def handle_event("test", %{"id" => id}, socket) do
    case AI.get_provider(id) do
      nil ->
        {:noreply, socket}

      provider ->
        {:noreply,
         socket
         |> update(:tests, &Map.put(&1, provider.id, :running))
         |> start_async({:test, provider.id}, fn -> AI.test_provider(provider) end)}
    end
  end

  def handle_event("save_feature", %{"feature" => key} = params, socket) do
    attrs = %{
      provider_id: blank_to_nil(params["provider_id"]),
      enabled: params["enabled"] == "true",
      staff_only: params["staff_only"] == "true"
    }

    case AI.update_feature(key, attrs, socket.assigns.current_user) do
      {:ok, _setting} ->
        {:noreply, socket |> put_flash(:info, "#{AI.feature(key).label} saved.") |> load()}

      {:error, changeset} ->
        message =
          Enum.map_join(changeset.errors, "; ", fn {_field, {message, _}} -> message end)

        {:noreply, put_flash(socket, :error, "#{AI.feature(key).label}: #{message}.")}
    end
  end

  @impl true
  def handle_async({:test, id}, {:ok, result}, socket) do
    {:noreply, update(socket, :tests, &Map.put(&1, id, result))}
  end

  def handle_async({:test, id}, {:exit, reason}, socket) do
    {:noreply, update(socket, :tests, &Map.put(&1, id, {:error, inspect(reason)}))}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp adapter_label(adapter),
    do: Enum.find_value(ProviderConfig.adapters(), fn {label, key} -> key == adapter && label end)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="AI" navigate={~p"/staff/ai"}>
        <:subtitle>Model providers, the features they serve, and what they've used.</:subtitle>
        <:actions>
          <.link navigate={~p"/staff/settings"} class="btn btn-sm">Quotas and prompts</.link>
        </:actions>
      </.page_header>

      <section id="ai-status" class="alert" role="status">
        <span :if={@enabled}>AI is <strong>on</strong>: the features switched on below are in use.</span>
        <span :if={!@enabled}>AI is <strong>off</strong>: nothing is sent to any provider.</span>
        <button id="toggle-ai" phx-click="toggle_ai" class="btn btn-sm">
          {if @enabled, do: "Turn AI off", else: "Turn AI on"}
        </button>
      </section>

      <section id="ai-providers" class="space-y-2">
        <h2 class="text-lg font-semibold">Providers</h2>
        <p :if={@providers == []} class="text-base-content/70">No providers yet.</p>
        <ul :if={@providers != []} class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
          <li :for={provider <- @providers} id={"provider-#{provider.id}"} class="space-y-1 p-3">
            <div class="flex flex-wrap items-center gap-2">
              <span class="flex-1 font-medium">{provider.name}</span>
              <span class="badge badge-sm">{adapter_label(provider.adapter)}</span>
              <code class="text-sm">{provider.model}</code>
              <span class="break-all text-sm text-base-content/70">{provider.base_url}</span>
              <span class={["badge badge-sm", provider.api_key && "badge-success"]}>
                {if provider.api_key, do: "Key set", else: "No key"}
              </span>
              <button phx-click="test" phx-value-id={provider.id} class="btn btn-xs">Test connection</button>
              <button phx-click="edit" phx-value-id={provider.id} class="btn btn-xs">Edit</button>
              <button
                phx-click="delete"
                phx-value-id={provider.id}
                data-confirm="Delete this provider? The features it serves are turned off."
                class="btn btn-xs btn-error"
              >
                Delete
              </button>
            </div>
            <.test_result result={@tests[provider.id]} id={"test-#{provider.id}"} />
          </li>
        </ul>
      </section>

      <.form for={@form} id="provider-form" phx-submit="save_provider" class="card border border-base-300 bg-base-100">
        <div class="card-body gap-2">
          <h2 class="card-title">{if @editing, do: "Edit #{@editing.name}", else: "Add a provider"}</h2>
          <.input field={@form[:name]} type="text" label="Name" />
          <.input field={@form[:adapter]} type="select" label="API" options={ProviderConfig.adapters()} />
          <.input
            field={@form[:base_url]}
            type="url"
            label="Base URL (blank: the API's own, e.g. https://api.openai.com/v1 or http://localhost:11434/v1 for Ollama)"
          />
          <.input
            field={@form[:api_key]}
            type="password"
            value=""
            autocomplete="off"
            label={if @editing, do: "API key (blank: keep the current one)", else: "API key (blank for local servers)"}
          />
          <.input :if={@editing} field={@form[:clear_api_key]} type="checkbox" label="Remove the stored key" />
          <.input field={@form[:model]} type="text" label="Model id" />
          <.input
            field={@form[:embedding_model]}
            type="text"
            label="Embedding model id (OpenAI-compatible APIs; blank: the model id)"
          />
          <.input field={@form[:max_tokens]} type="number" label="Most tokens per answer" />
          <.input field={@form[:timeout_seconds]} type="number" label="Timeout (seconds)" />
          <.input
            field={@form[:allow_private]}
            type="checkbox"
            label="Allow private addresses (a model served on this machine or network)"
          />
          <div class="flex justify-end gap-2">
            <button :if={@editing} type="button" phx-click="cancel" class="btn">Cancel</button>
            <.button variant="primary" phx-disable-with="Saving...">
              {if @editing, do: "Save provider", else: "Add provider"}
            </.button>
          </div>
        </div>
      </.form>

      <section id="ai-features" class="space-y-2">
        <h2 class="text-lg font-semibold">Features</h2>
        <div :for={feature <- AI.features()} class="card border border-base-300 bg-base-100">
          <form id={"feature-#{feature.key}"} phx-submit="save_feature" class="card-body gap-2">
            <input type="hidden" name="feature" value={feature.key} />
            <h3 class="font-medium">{feature.label}</h3>
            <p class="text-sm text-base-content/70">{feature.description}</p>
            <div class="flex flex-wrap items-center gap-3">
              <label class="flex items-center gap-1 text-sm">
                Provider
                <select name="provider_id" class="select select-sm">
                  <option value="">None</option>
                  {Phoenix.HTML.Form.options_for_select(@provider_options, @settings[feature.key].provider_id)}
                </select>
              </label>
              <label class="flex items-center gap-1 text-sm">
                <input type="hidden" name="enabled" value="false" />
                <input
                  type="checkbox"
                  name="enabled"
                  value="true"
                  checked={@settings[feature.key].enabled}
                  class="checkbox checkbox-sm"
                /> On
              </label>
              <label :if={!feature.system} class="flex items-center gap-1 text-sm">
                <input type="hidden" name="staff_only" value="false" />
                <input
                  type="checkbox"
                  name="staff_only"
                  value="true"
                  checked={@settings[feature.key].staff_only}
                  class="checkbox checkbox-sm"
                /> Staff only
              </label>
              <button class="btn btn-sm">Save</button>
            </div>
          </form>
        </div>
      </section>

      <section id="ai-prompts" class="space-y-2">
        <h2 class="text-lg font-semibold">Prompts</h2>
        <p class="text-sm text-base-content/70">
          Built into Firefly; override one in the AI prompts site settings.
        </p>
        <details :for={name <- Prompts.names()} id={"prompt-#{name}"} class="rounded-box border border-base-300 bg-base-100 p-3">
          <summary class="cursor-pointer">
            {name}
            <span :if={SiteSettings.customized?(Prompts.setting(name))} class="badge badge-sm badge-info">
              overridden
            </span>
          </summary>
          <pre class="mt-2 whitespace-pre-wrap text-sm">{Prompts.default(name)}</pre>
        </details>
      </section>

      <section id="ai-usage" class="space-y-2">
        <div class="flex items-center gap-2">
          <h2 class="flex-1 text-lg font-semibold">Usage, last 30 days</h2>
          <.link navigate={~p"/staff/reports/ai_usage"} class="link text-sm">Report</.link>
        </div>
        <p :if={@usage == []} class="text-base-content/70">Nothing yet.</p>
        <div :if={@usage != []} class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Day</th>
                <th>Feature</th>
                <th>Member</th>
                <th class="text-right">Requests</th>
                <th class="text-right">Tokens in</th>
                <th class="text-right">Tokens out</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @usage}>
                <td>{row.day}</td>
                <td>{row.feature}</td>
                <td>{if row.user, do: "@" <> row.user.username, else: "System"}</td>
                <td class="text-right">{row.requests}</td>
                <td class="text-right">{row.input_tokens}</td>
                <td class="text-right">{row.output_tokens}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :result, :any, required: true
  attr :id, :string, required: true

  defp test_result(%{result: nil} = assigns), do: ~H""

  defp test_result(%{result: :running} = assigns) do
    ~H"""
    <p id={@id} class="text-sm text-base-content/70">Testing…</p>
    """
  end

  defp test_result(%{result: {:ok, _}} = assigns) do
    ~H"""
    <p id={@id} class="flex flex-wrap items-center gap-2 text-sm text-success">
      Connected in {elem(@result, 1).ms} ms. <.ai_label />
      <span class="text-base-content">{elem(@result, 1).text}</span>
    </p>
    """
  end

  defp test_result(%{result: {:error, _}} = assigns) do
    ~H"""
    <p id={@id} class="text-sm text-error">Failed: {elem(@result, 1)}</p>
    """
  end
end
