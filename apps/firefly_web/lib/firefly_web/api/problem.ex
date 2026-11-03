defmodule FireflyWeb.Api.Problem do
  @moduledoc """
  API errors as RFC 9457 (formerly 7807) problem details:
  `application/problem+json` bodies with `type`, `title` (the status's
  reason phrase), `status` and `detail`, plus `errors` (field name to
  messages) for validation failures. `type` links to the error's section
  of the API docs.
  """
  import Plug.Conn

  @doc "Sends a problem response with `status` and `detail`, and halts."
  def send(conn, status, detail, extra \\ %{}) do
    status = Plug.Conn.Status.code(status)
    title = Plug.Conn.Status.reason_phrase(status)

    body =
      Map.merge(
        %{
          type: "#{FireflyWeb.Endpoint.url()}/api/v1/docs#problem-#{slug(title)}",
          title: title,
          status: status,
          detail: detail
        },
        extra
      )

    conn
    |> put_resp_content_type("application/problem+json")
    |> send_resp(status, Jason.encode_to_iodata!(body))
    |> halt()
  end

  @doc "A 422 problem listing a changeset's errors by field."
  def changeset(conn, %Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, &FireflyWeb.CoreComponents.translate_error/1)

    send(conn, 422, "The request has invalid fields.", %{errors: errors})
  end

  defp slug(title), do: title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
end
