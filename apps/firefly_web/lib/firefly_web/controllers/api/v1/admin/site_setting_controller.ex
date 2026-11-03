defmodule FireflyWeb.Api.V1.Admin.SiteSettingController do
  @moduledoc """
  Site settings (admins; `admin` scope): every setting with its section,
  type and value (secret ones masked), and saving some (`{"key":
  value}`), validated and logged as on `/staff/settings`.
  """
  use FireflyWeb, :controller
  import FireflyWeb.Api.Helpers

  alias Firefly.SiteSettings

  action_fallback(FireflyWeb.Api.V1.FallbackController)

  plug(:require_scope, "admin")

  def index(conn, _params) do
    with :ok <- permit(current_user(conn), :manage_site_settings), do: ok(conn, settings())
  end

  def update(conn, params) do
    params = Map.drop(params, ["format"])

    with :ok <- permit(current_user(conn), :manage_site_settings) do
      case SiteSettings.update(params, current_user(conn)) do
        {:ok, _changes} ->
          ok(conn, settings())

        {:error, errors} ->
          FireflyWeb.Api.Problem.send(conn, 422, "The request has invalid fields.", %{
            errors: Map.new(errors, fn {key, message} -> {key, [message]} end)
          })
      end
    end
  end

  defp settings do
    values = SiteSettings.all()

    for definition <- SiteSettings.definitions() do
      value = values[definition.key]

      %{
        key: definition.key,
        section: definition.section,
        type: definition.type,
        label: definition.label,
        value: if(definition[:secret] && value not in [nil, ""], do: "[secret]", else: value),
        default: definition.default
      }
    end
  end
end
