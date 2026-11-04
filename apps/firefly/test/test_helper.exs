# `:ldap` tests need a directory server (see Firefly.LDAPTestDirectory).
# `:fuzz` tests are the deep property runs (see "Tests" in the README).
# `:cluster` tests start a second node (see Firefly.ClusterNodesTest).
ExUnit.configure(exclude: [pending: true, ldap: true, fuzz: true, cluster: true])

# Run alone (`cd apps/firefly && mix test`), the domain has no web
# interface to link to and broadcast through: stand one in.
if !Code.ensure_loaded?(FireflyWeb.Endpoint) do
  Application.put_env(:firefly, Firefly.Endpoint, impl: Firefly.TestEndpoint)
end

# Uploads stored by earlier runs (see config/test.exs).
File.rm_rf!(Application.fetch_env!(:firefly, Firefly.Uploads)[:local_dir])

# More property runs (see "Tests" in the README) take longer than a test may.
if System.get_env("FIREFLY_PROPERTY_RUNS"), do: ExUnit.configure(timeout: :infinity)

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(Firefly.Repo, :manual)
