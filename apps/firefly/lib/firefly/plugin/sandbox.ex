defmodule Firefly.Plugin.Sandbox do
  @moduledoc """
  The runtime uploaded plugins run in: a `Firefly.Plugin` implementation
  that loads each installed bundle, and turns a bundle's files into the
  code it runs. (Packages are read and validated by the domain, see
  `Firefly.Packages.Archive`.)

  The domain has no sandbox of its own: the `:firefly_plugins` app
  registers its implementation when it starts (see
  `Firefly.Plugins.Registry.register_sandbox/1`), so the domain
  never depends on it. Without one, uploaded plugins don't load and bundles
  can't be installed; core plugins work as usual.
  """

  alias Firefly.Plugin.Manifest

  @typedoc "A read bundle: its manifest, the zip and the zip's SHA-256."
  @type bundle :: %{
          required(:manifest) => Manifest.t(),
          required(:checksum) => String.t(),
          required(:zip) => binary,
          optional(atom) => term
        }

  @doc "The code stored for `bundle`, which `c:Firefly.Plugin.load/1` gets back."
  @callback bundle_code(bundle) :: String.t()

  @doc "Prepares the runtime (e.g. compiles it), so the first call doesn't pay for it."
  @callback warm_up() :: term

  @key {__MODULE__, :implementation}

  @doc "Registers `module` (implementing this and `Firefly.Plugin`) as the sandbox."
  @spec register(module) :: :ok
  def register(module) when is_atom(module), do: :persistent_term.put(@key, module)

  @doc "The registered sandbox, or nil."
  @spec implementation() :: module | nil
  def implementation, do: :persistent_term.get(@key, nil)
end
