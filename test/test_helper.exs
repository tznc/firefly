ExUnit.configure(exclude: [pending: true])

# End-to-end browser tests (tagged :e2e) need Playwright; see README.
{:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
Application.put_env(:phoenix_test, :base_url, FirestormWeb.Web.Endpoint.url())

# Uploads stored by earlier runs (see config/test.exs).
File.rm_rf!(Application.fetch_env!(:firestorm_web, FirestormWeb.Uploads)[:local_dir])

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(FirestormWeb.Repo, :manual)
