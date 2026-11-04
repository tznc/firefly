# `:ldap` tests need a directory server (see Firefly.LDAPTestDirectory).
ExUnit.configure(exclude: [pending: true, ldap: true])

# Run alone (`cd apps/firefly && mix test`), the domain has no web
# interface to link to and broadcast through: stand one in.
if !Code.ensure_loaded?(FireflyWeb.Endpoint) do
  Application.put_env(:firefly, Firefly.Endpoint, impl: Firefly.TestEndpoint)
end

# Uploads stored by earlier runs (see config/test.exs).
File.rm_rf!(Application.fetch_env!(:firefly, Firefly.Uploads)[:local_dir])

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(Firefly.Repo, :manual)
