defmodule Firefly.Endpoint do
  @moduledoc """
  The domain's port to the web interface: the site's base URL, the secret
  tokens are signed with, and broadcasts to connected clients (channels and
  LiveViews).

  The implementation is a Phoenix endpoint, configured rather than
  referenced, so the domain doesn't depend on the web app:

      config :firefly, Firefly.Endpoint, impl: FireflyWeb.Endpoint
  """

  @doc "The site's base URL, e.g. `\"https://firefly.tznc.dev\"`."
  @callback url() :: String.t()

  @doc "`path` under the site's base path (`\"/\"` unless it's served under one)."
  @callback path(String.t()) :: String.t()

  @doc "A configuration value, e.g. `:secret_key_base`."
  @callback config(atom) :: term

  @doc "Broadcasts `event` with `payload` to the clients subscribed to `topic`."
  @callback broadcast(String.t(), String.t(), term) :: :ok | {:error, term}

  @doc "Like `c:broadcast/3`, raising on errors."
  @callback broadcast!(String.t(), String.t(), term) :: :ok

  @spec url() :: String.t()
  def url, do: impl().url()

  @spec path(String.t()) :: String.t()
  def path(path), do: impl().path(path)

  @doc "The secret key base tokens are signed with (see `sign/3`)."
  @spec secret_key_base() :: String.t()
  def secret_key_base, do: impl().config(:secret_key_base)

  @spec broadcast(String.t(), String.t(), term) :: :ok | {:error, term}
  def broadcast(topic, event, payload), do: impl().broadcast(topic, event, payload)

  @spec broadcast!(String.t(), String.t(), term) :: :ok
  def broadcast!(topic, event, payload), do: impl().broadcast!(topic, event, payload)

  @doc """
  Signs `data` with `salt`: the same token `Phoenix.Token.sign/3` gives for
  the endpoint, so links already sent keep working.
  """
  @spec sign(String.t(), term) :: String.t()
  def sign(salt, data), do: Plug.Crypto.sign(secret_key_base(), salt, data)

  @doc "Verifies a token from `sign/2`, like `Phoenix.Token.verify/4`."
  @spec verify(String.t(), String.t(), keyword) :: {:ok, term} | {:error, atom}
  def verify(salt, token, opts \\ []),
    do: Plug.Crypto.verify(secret_key_base(), salt, token, opts)

  defp impl, do: Application.fetch_env!(:firefly, __MODULE__)[:impl]
end
