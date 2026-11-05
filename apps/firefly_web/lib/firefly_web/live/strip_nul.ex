defmodule FireflyWeb.LiveStripNul do
  @moduledoc """
  Strips NUL characters (see `Firefly.Text`) from what reaches a LiveView
  or LiveComponent over its socket, websocket or long poll alike: the
  params of `mount/3` and `handle_params/3` (the URL) and of
  `handle_event/3`. `use FireflyWeb, :live_view` and `:live_component`
  use it.

  It wraps the callbacks rather than decoding frames in a socket
  serializer because LiveView sends forms URL-encoded inside the frame
  (`%00`), and the URL as a string: a serializer would have to redo
  LiveView's own decoding, while the callbacks get the params as the code
  sees them.

  An event the database still refuses for its text (see
  `FireflyWeb.UnstorableText`) flashes an error instead of crashing the
  LiveView.
  """

  alias FireflyWeb.UnstorableText

  defmacro __using__(_opts) do
    quote do
      @before_compile FireflyWeb.LiveStripNul
    end
  end

  defmacro __before_compile__(env) do
    wrappers =
      for callback <- [:mount, :handle_params, :handle_event],
          Module.defines?(env.module, {callback, 3}, :def),
          do: wrap(callback)

    {:__block__, [], wrappers}
  end

  defp wrap(:mount) do
    quote do
      defoverridable mount: 3

      @impl true
      def mount(params, session, socket),
        do: super(Firefly.Text.strip_nul(params), session, socket)
    end
  end

  defp wrap(:handle_params) do
    quote do
      defoverridable handle_params: 3

      @impl true
      def handle_params(params, uri, socket),
        do: super(Firefly.Text.strip_nul(params), uri, socket)
    end
  end

  defp wrap(:handle_event) do
    quote do
      defoverridable handle_event: 3

      @impl true
      def handle_event(event, params, socket) do
        super(event, Firefly.Text.strip_nul(params), socket)
      rescue
        error in Postgrex.Error -> FireflyWeb.LiveStripNul.refused(error, socket, __STACKTRACE__)
      end
    end
  end

  @doc false
  def refused(error, socket, stacktrace) do
    if UnstorableText.error?(error),
      do: {:noreply, Phoenix.LiveView.put_flash(socket, :error, UnstorableText.message())},
      else: reraise(error, stacktrace)
  end
end
