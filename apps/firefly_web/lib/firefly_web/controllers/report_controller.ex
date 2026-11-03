defmodule FireflyWeb.ReportController do
  @moduledoc "A report as CSV (admins only, behind the `:admin` pipeline; see `Firefly.Reports`)."
  use FireflyWeb, :controller

  alias Firefly.Reports

  def export(conn, %{"id" => id} = params) do
    case Reports.get(id) do
      nil ->
        send_resp(conn, 404, "No such report.")

      report ->
        range = Reports.range(params)
        %{result: result} = Reports.run(report, range)

        conn
        |> put_resp_content_type("text/csv")
        |> put_resp_header(
          "content-disposition",
          ~s{attachment; filename="#{report.id()}-#{range.from}-#{range.to}.csv"}
        )
        |> send_resp(200, Reports.to_csv(result))
    end
  end
end
