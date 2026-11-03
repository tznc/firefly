defmodule Firefly.TestEndpoint do
  @moduledoc """
  A `Firefly.Endpoint` for the domain's own tests, which run without the
  web app: the test endpoint's URL and secret, and broadcasts on
  `Firefly.PubSub` as `{:broadcast, topic, event, payload}`.
  """

  # Test support, for any app's tests: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]
  @behaviour Firefly.Endpoint

  @impl true
  def url, do: "http://localhost:4002"

  @impl true
  def path(path), do: path

  @impl true
  def config(:secret_key_base), do: String.duplicate("firefly-test-secret-", 4)

  @impl true
  def broadcast(topic, event, payload),
    do: Phoenix.PubSub.broadcast(Firefly.PubSub, topic, {:broadcast, topic, event, payload})

  @impl true
  def broadcast!(topic, event, payload), do: :ok = broadcast(topic, event, payload)
end
