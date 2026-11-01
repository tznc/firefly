defmodule FirestormWeb.Web.StaffLive.Log do
  @moduledoc """
  The staff log (admins only): every staff action, newest first, filterable
  by action and by who took it. Targets link to their page while they exist;
  a deleted target is shown from the details the log kept.
  """
  use FirestormWeb.Web, :live_view

  on_mount({FirestormWeb.Web.UserAuth, :require_user})

  alias FirestormWeb.StaffLog

  @labels %{
    "thread.pin" => "Pinned thread",
    "thread.unpin" => "Unpinned thread",
    "thread.close" => "Closed thread",
    "thread.open" => "Reopened thread",
    "thread.archive" => "Archived thread",
    "thread.unarchive" => "Unarchived thread",
    "thread.move" => "Moved thread",
    "thread.edit" => "Edited thread",
    "thread.delete" => "Deleted thread",
    "post.edit" => "Edited post",
    "post.delete" => "Deleted post",
    "post.restore" => "Restored post",
    "category.create" => "Created category",
    "category.update" => "Updated category",
    "category.delete" => "Deleted category",
    "role.grant" => "Granted role",
    "role.revoke" => "Revoked role",
    "user.silence" => "Silenced user",
    "user.unsilence" => "Lifted silence",
    "user.suspend" => "Suspended user",
    "user.unsuspend" => "Lifted suspension",
    "setting.update" => "Changed setting",
    "admin.create" => "Created in admin",
    "admin.update" => "Updated in admin",
    "admin.delete" => "Deleted in admin"
  }

  @impl true
  def mount(_params, _session, socket) do
    if can?(socket.assigns.current_user, :view_staff_log) do
      {:ok,
       socket
       |> assign(:page_title, "Staff log")
       |> assign(:linked_types, StaffLog.linked_types())
       |> assign(:actors, Enum.map(StaffLog.actors(), &{&1.username, &1.id}))
       |> assign(:action_options, Enum.map(StaffLog.actions(), &{@labels[&1], &1}))}
    else
      {:ok,
       socket
       |> put_flash(:error, denied_message(socket.assigns.current_user))
       |> push_navigate(to: ~p"/")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = %{
      "action" => if(params["action"] in StaffLog.actions(), do: params["action"]),
      "actor" =>
        case Integer.parse(params["actor"] || "") do
          {id, ""} -> id
          _ -> nil
        end
    }

    page = StaffLog.list(filters, params["page"])

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:form, to_form(Map.new(filters, fn {k, v} -> {k, v && to_string(v)} end)))
     |> assign(:log, page)
     |> assign(:targets, StaffLog.targets(page.entries))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    query = params |> Map.take(["action", "actor"]) |> Enum.reject(fn {_, v} -> v == "" end)
    {:noreply, push_patch(socket, to: ~p"/staff/log?#{Map.new(query)}")}
  end

  defp label(action), do: Map.get(@labels, action, action)

  # The target's page (and how to name it), or nil once it's gone.
  defp target_link(%{target_type: "setting", details: %{"key" => key}}, _target),
    do: {key, ~p"/staff/settings"}

  defp target_link(_entry, nil), do: nil

  defp target_link(%{target_type: "thread"}, thread),
    do: {thread.title, ~p"/categories/#{thread.category_id}/threads/#{thread}"}

  defp target_link(%{target_type: "post"}, post),
    do:
      {"Post in #{post.thread.title}",
       ~p"/categories/#{post.thread.category_id}/threads/#{post.thread}" <> "#post-#{post.id}"}

  defp target_link(%{target_type: "category"}, category),
    do: {category.title, ~p"/categories/#{category}"}

  defp target_link(%{target_type: "user"}, user), do: {"@#{user.username}", ~p"/users/#{user}"}

  defp query_params(filters),
    do: for({k, v} <- filters, v, into: %{}, do: {k, to_string(v)})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app {Layouts.shell(assigns)}>
      <.page_header title="Staff log" navigate={~p"/staff/log"}>
        <:subtitle>Every action staff took, newest first.</:subtitle>
      </.page_header>

      <.form for={@form} id="staff-log-filters" phx-change="filter" class="flex flex-wrap gap-4">
        <.input
          field={@form[:action]}
          type="select"
          label="Action"
          prompt="Any action"
          options={@action_options}
        />
        <.input field={@form[:actor]} type="select" label="Staff" prompt="Anyone" options={@actors} />
      </.form>

      <p :if={@log.entries == []} id="staff-log-empty" class="text-base-content/70">
        No staff actions yet.
      </p>

      <div :if={@log.entries != []} class="overflow-x-auto">
        <table id="staff-log" class="table">
          <thead>
            <tr>
              <th>When</th>
              <th>Staff</th>
              <th>Action</th>
              <th>Target</th>
              <th>Details</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @log.entries} id={"staff-action-#{entry.id}"} class="align-top">
              <td class="whitespace-nowrap text-sm">
                <.time_ago at={entry.inserted_at} id={"staff-action-#{entry.id}-at"} />
              </td>
              <td>
                <.link :if={entry.actor} navigate={~p"/users/#{entry.actor}"} class="link">
                  {entry.actor.username}
                </.link>
              </td>
              <td class="whitespace-nowrap">{label(entry.action)}</td>
              <td class="target">
                <%= case target_link(entry, @targets[{entry.target_type, entry.target_id}]) do %>
                  <% nil -> %>
                    <span class="text-base-content/60">
                      {if entry.target_type in @linked_types, do: "Deleted "}{entry.target_type} #{entry.target_id}
                    </span>
                  <% {name, path} -> %>
                    <.link navigate={path} class="link">{name}</.link>
                <% end %>
              </td>
              <td class="details text-sm">
                <.details details={entry.details} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <.pagination page={@log} path={~p"/staff/log"} params={query_params(@filters)} />
    </Layouts.app>
    """
  end

  attr :details, :map, required: true

  # Each detail as "field: value"; edits as "before → after", collapsed
  # when long (e.g. a post body).
  defp details(assigns) do
    ~H"""
    <dl class="space-y-1">
      <div :for={{key, value} <- Enum.sort(@details)} class="flex gap-1">
        <dt class="font-medium">{String.replace(key, "_", " ")}:</dt>
        <dd class="min-w-0 break-words">
          <%= case value do %>
            <% %{"before" => before, "after" => after_value} -> %>
              <%= if String.length("#{before}#{after_value}") > 80 do %>
                <details>
                  <summary class="cursor-pointer">changed</summary>
                  <p class="whitespace-pre-wrap"><del>{before}</del></p>
                  <p class="whitespace-pre-wrap"><ins>{after_value}</ins></p>
                </details>
              <% else %>
                <del>{before}</del> → <ins>{after_value}</ins>
              <% end %>
            <% _ -> %>
              {value}
          <% end %>
        </dd>
      </div>
    </dl>
    """
  end
end
