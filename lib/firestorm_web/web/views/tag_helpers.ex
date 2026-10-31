defmodule FirestormWeb.Web.TagHelpers do
  @moduledoc """
  View helpers for generating particular tags with some internal logic
  """

  import PhoenixHTMLHelpers.Tag

  @doc """
  Generate an abbr to wrap an ISO time to be rendered nicely via JS in the frontend.
  """
  def time_abbr(time) do
    time_string =
      time
      |> to_utc_datetime()
      |> DateTime.to_iso8601()

    content_tag(:abbr, class: "time", title: time_string) do
      time_string
    end
  end

  defp to_utc_datetime(%DateTime{} = time), do: DateTime.shift_zone!(time, "Etc/UTC")
  defp to_utc_datetime(%NaiveDateTime{} = time), do: DateTime.from_naive!(time, "Etc/UTC")
end
