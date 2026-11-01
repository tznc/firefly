ExUnit.configure(exclude: [pending: true])

# End-to-end browser tests (tagged :e2e) need Playwright; see README.
{:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
Application.put_env(:phoenix_test, :base_url, FirestormWeb.Web.Endpoint.url())

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(FirestormWeb.Repo, :manual)
