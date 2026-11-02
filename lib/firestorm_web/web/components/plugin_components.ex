defmodule FirestormWeb.Web.PluginComponents do
  @moduledoc """
  Where plugins show up in pages: widget outlets and plugin views (see
  `FirestormWeb.Plugins.UI`).
  """
  use Phoenix.Component

  alias FirestormWeb.Forums
  alias FirestormWeb.Forums.Post
  alias FirestormWeb.Plugins.UI

  @doc """
  The active plugins' widgets for `outlet`, each in a sandboxed frame.
  Widgets about a post or thread (`post`/`thread` given) only show on
  content anonymous visitors can read.
  """
  attr :outlet, :string, required: true
  attr :key, :any, default: nil, doc: "tells apart several outlets of the same kind on a page"
  attr :context, :map, default: %{}
  attr :user, :any, default: nil
  attr :thread, :any, default: nil
  attr :post, :any, default: nil

  def plugin_outlet(assigns) do
    widgets = UI.widgets(assigns.outlet)
    widgets = if widgets != [] and public?(assigns.post, assigns.thread), do: widgets, else: []
    assigns = assign(assigns, :widgets, widgets)

    ~H"""
    <div :if={@widgets != []} class={"plugin-outlet plugin-outlet-#{@outlet} space-y-2"}>
      <.plugin_frame
        :for={{plugin, widget} <- @widgets}
        id={Enum.join(["plugin", plugin.id, @outlet, @key], "-")}
        plugin={plugin}
        asset={widget["asset"]}
        height={widget["height"] || 100}
        context={@context}
        user={@user}
      />
    </div>
    """
  end

  defp public?(nil, nil), do: true
  defp public?(nil, thread), do: Bodyguard.permit?(Forums, :view_thread, nil, thread)
  defp public?(post, thread), do: Post.readable_by?(post, nil) and public?(nil, thread)

  @doc "One plugin asset in a sandboxed frame, wired to the widget bridge."
  attr :id, :string, required: true
  attr :plugin, :any, required: true
  attr :asset, :string, required: true
  attr :height, :integer, default: 100
  attr :context, :map, default: %{}
  attr :user, :any, default: nil
  attr :class, :string, default: "w-full rounded-box border-0"

  def plugin_frame(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="PluginWidget"
      phx-update="ignore"
      data-plugin={@plugin.id}
      data-context={Jason.encode!(@context)}
      data-user={Jason.encode!(UI.public_user(@user))}
    >
      <iframe
        sandbox="allow-scripts"
        src={"/plugins/#{@plugin.id}/assets/#{@asset}"}
        referrerpolicy="no-referrer"
        loading="lazy"
        title={@plugin.manifest.name}
        class={@class}
        style={"height: #{@height}px"}
      >
      </iframe>
    </div>
    """
  end

  @doc "A plugin's page or staff section (see `FirestormWeb.Plugins.UI.render/3`)."
  attr :id, :string, required: true
  attr :plugin, :any, required: true
  attr :view, :map, required: true
  attr :context, :map, default: %{}
  attr :user, :any, default: nil

  def plugin_view(assigns) do
    ~H"""
    <div :if={@view[:html]} id={@id} class="plugin-view prose max-w-none">
      {Phoenix.HTML.raw(@view.html)}
    </div>
    <.plugin_frame
      :if={@view[:iframe]}
      id={@id}
      plugin={@plugin}
      asset={@view.iframe}
      height={600}
      context={@context}
      user={@user}
    />
    """
  end
end
