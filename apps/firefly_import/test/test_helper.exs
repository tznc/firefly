ExUnit.configure(exclude: [pending: true])

# The importers don't need the web interface: stand one in for links.
if !Code.ensure_loaded?(FireflyWeb.Endpoint) do
  Application.put_env(:firefly, Firefly.Endpoint, impl: Firefly.TestEndpoint)
end

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(Firefly.Repo, :manual)
