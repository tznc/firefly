defmodule FireflyPlugins do
  @moduledoc """
  The sandbox uploaded plugins run in: `FireflyPlugins.Sandboxed` (the
  `Firefly.Plugin` and `Firefly.Plugin.Sandbox` implementation, registered
  with the domain when this app starts), `FireflyPlugins.Runtime` (QuickJS
  on WebAssembly) and `FireflyPlugins.Bundle` (reading uploaded bundles).
  """

  use Boundary,
    top_level?: true,
    deps: [Firefly, Firefly.Plugin, Firefly.Plugins],
    exports: [Bundle, Sandboxed]
end
