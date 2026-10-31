# Feature (browser) tests need chromedriver + Chrome; run them with
# `mix test --include feature`.
ExUnit.configure(exclude: [pending: true, feature: true])
ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(FirestormWeb.Repo, :manual)

Application.put_env(:firestorm_web, :get_session_from_cookies, true)

if :feature in Keyword.get(ExUnit.configuration(), :include, []) do
  {:ok, _} = Application.ensure_all_started(:wallaby)
  Application.put_env(:wallaby, :base_url, FirestormWeb.Web.Endpoint.url())
end
