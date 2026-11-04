defmodule FireflyPlugins do
  @moduledoc """
  The sandbox uploaded plugins run in: `FireflyPlugins.Sandboxed` (the
  `Firefly.Plugin` and `Firefly.Plugin.Sandbox` implementation, registered
  with the domain when this app starts), `FireflyPlugins.Runtime` (QuickJS
  on WebAssembly) and `FireflyPlugins.Bundle` (a package's plugin code as one script).
  """

  use Boundary,
    top_level?: true,
    deps: [Firefly, Firefly.Plugin, Firefly.Plugins, Firefly.Packages],
    exports: [Bundle, Sandboxed]
end
