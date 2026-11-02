defmodule FirestormWeb.Web.PluginWidgets do
  @moduledoc """
  Answers plugin widgets' calls (the `PluginWidget` hook's
  `"plugin_widget_call"` event) in every LiveView of the default
  `live_session`, by running the plugin's `handle_widget` hook, and their
  storage requests (`"plugin_widget_storage"`) against the viewer's own
  store (see `FirestormWeb.Plugins.UI`).
  """
  import Phoenix.LiveView

  alias FirestormWeb.Plugins.UI
  alias FirestormWeb.Web.ClientIP

  def on_mount(:default, _params, _session, socket) do
    # Rate limited per member, or per client IP for visitors; the IP is
    # only known while mounting.
    caller =
      case socket.assigns[:current_user] do
        %{id: id} -> "user:#{id}"
        nil -> "ip:#{socket |> ClientIP.from_socket() |> format()}"
      end

    {:cont,
     attach_hook(socket, :plugin_widgets, :handle_event, &handle_event(&1, &2, &3, caller))}
  end

  defp handle_event(
         "plugin_widget_call",
         %{"plugin" => id, "handler" => handler} = params,
         socket,
         caller
       )
       when is_binary(id) and is_binary(handler) do
    reply =
      case UI.call_widget(
             id,
             handler,
             params["args"],
             params["context"],
             socket.assigns[:current_user],
             caller
           ) do
        {:ok, result} -> %{ok: result}
        {:error, message} -> %{error: message}
      end

    {:halt, reply, socket}
  end

  # The viewer's own storage: always the logged-in user's, whatever the
  # widget sent.
  defp handle_event("plugin_widget_storage", %{"plugin" => id, "op" => op} = params, socket, _)
       when is_binary(id) and is_binary(op) do
    reply =
      case UI.widget_storage(id, op, params, socket.assigns[:current_user]) do
        {:ok, result} -> %{ok: result}
        {:error, message} -> %{error: message}
      end

    {:halt, reply, socket}
  end

  defp handle_event(_event, _params, socket, _caller), do: {:cont, socket}

  defp format(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format(ip), do: to_string(ip)
end
