defmodule FireflyWeb.ApiHelpers do
  @moduledoc """
  Helpers for API tests: requests with a user's key, and checking
  responses against the OpenAPI document's schemas
  (`FireflyWeb.Api.V1.OpenAPI`).
  """
  import ExUnit.Assertions
  import Plug.Conn, only: [put_req_header: 3]

  @doc "A connection carrying a new key for `user` with `scopes` (default: all)."
  def authed(conn, user, scopes \\ Firefly.Accounts.ApiKeys.full_scopes()),
    do:
      put_req_header(conn, "authorization", "Bearer #{Firefly.Fixtures.api_token(user, scopes)}")

  @doc "Asserts `value` matches the component schema `name`, and returns it."
  def assert_schema(value, name) do
    case ExJsonSchema.Validator.validate_fragment(root(), "#/components/schemas/#{name}", value) do
      :ok ->
        value

      {:error, errors} ->
        flunk("#{name} doesn't match its schema: #{inspect(errors)}\n#{inspect(value)}")
    end
  end

  @doc "Asserts a list response's `data` items match `name`; returns the data."
  def assert_list(%{"data" => data, "meta" => meta}, name) do
    assert_schema(meta, "Meta")
    Enum.each(data, &assert_schema(&1, name))
    data
  end

  defp root do
    case :persistent_term.get({__MODULE__, :root}, nil) do
      nil ->
        schemas = Jason.decode!(Jason.encode!(FireflyWeb.Api.V1.OpenAPI.schemas()))
        root = ExJsonSchema.Schema.resolve(%{"components" => %{"schemas" => schemas}})
        :persistent_term.put({__MODULE__, :root}, root)
        root

      root ->
        root
    end
  end
end
