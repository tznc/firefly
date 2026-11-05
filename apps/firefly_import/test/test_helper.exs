# Tests tagged :import_mysql, :import_mongo or :import_redis read a source
# database on such a server (see FireflyImport.SourceDatabases): CI runs them
# with service containers; locally, start one (e.g. `docker run -p 3306:3306
# -e MARIADB_ROOT_PASSWORD=root mariadb:11`) and run
# `mix test --include import_mysql`.
ExUnit.configure(exclude: [:pending, :import_mysql, :import_mongo, :import_redis, :fuzz])

# The importers don't need the web interface: stand one in for links.
if !Code.ensure_loaded?(FireflyWeb.Endpoint) do
  Application.put_env(:firefly, Firefly.Endpoint, impl: Firefly.TestEndpoint)
end

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(Firefly.Repo, :manual)
Ecto.Adapters.SQL.Sandbox.mode(Firefly.Control.Repo, :manual)
