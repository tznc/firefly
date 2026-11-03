defmodule FireflyWeb.AIComposer do
  @moduledoc """
  The composer's AI helpers (see `Firefly.AI.Composer`) for any LiveView
  with a composer: `attach/4` handles the `ai_helper`, `ai_apply` and
  `ai_dismiss` events and runs the helper in the background, and the
  page renders `FireflyWeb.AIComponents.composer_helpers/1` with
  `@ai_helpers` and `@ai_suggestion`. Nothing changes the draft until the
  member picks "Use this".
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, start_async: 3]

  alias Firefly.AI
  alias Firefly.AI.Composer

  @doc """
  Offers the `only` helpers (of `[:proofread, :title, :tags]`) the member
  may use. `text` gets the draft's text from the socket; `apply` puts a
  suggestion (`helper`, value) into the socket's form.
  """
  def attach(socket, only, text, apply) do
    user = socket.assigns.current_user

    socket
    |> assign(:ai_helpers, Enum.filter(Composer.helpers(user), &(&1 in only)))
    |> assign(:ai_suggestion, nil)
    |> attach_hook(:ai_composer, :handle_event, &event(&1, &2, &3, text, apply))
    |> attach_hook(:ai_composer, :handle_async, &async/3)
  end

  defp event("ai_helper", %{"helper" => name}, socket, text, _apply) do
    case Enum.find(socket.assigns.ai_helpers, &(Atom.to_string(&1) == name)) do
      nil ->
        {:halt, socket}

      helper ->
        user = socket.assigns.current_user
        draft = text.(socket)

        {:halt,
         socket
         |> assign(:ai_suggestion, %{helper: helper, status: :loading})
         |> start_async(:ai_composer, fn -> run(helper, user, draft) end)}
    end
  end

  defp event("ai_apply", _params, socket, _text, apply) do
    case socket.assigns.ai_suggestion do
      %{status: :done, helper: helper, value: value} ->
        {:halt, socket |> apply.(helper, value) |> assign(:ai_suggestion, nil)}

      _none ->
        {:halt, socket}
    end
  end

  defp event("ai_dismiss", _params, socket, _text, _apply),
    do: {:halt, assign(socket, :ai_suggestion, nil)}

  defp event(_event, _params, socket, _text, _apply), do: {:cont, socket}

  defp run(:proofread, user, text), do: Composer.proofread(user, text)
  defp run(:title, user, text), do: Composer.suggest_title(user, text)
  defp run(:tags, user, text), do: Composer.suggest_tags(user, text)

  defp async(:ai_composer, result, socket) do
    status =
      case result do
        {:ok, {:ok, value}} -> %{status: :done, value: value}
        {:ok, {:error, reason}} -> %{status: {:error, AI.message(reason)}}
        {:exit, _reason} -> %{status: {:error, AI.message(:provider_failed)}}
      end

    suggestion = socket.assigns.ai_suggestion && Map.merge(socket.assigns.ai_suggestion, status)
    {:halt, assign(socket, :ai_suggestion, suggestion)}
  end

  defp async(_name, _result, socket), do: {:cont, socket}
end
