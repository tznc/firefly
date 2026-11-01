defmodule FirestormWeb.Forums.Diff do
  @moduledoc """
  Word-level diffs between two versions of a post body, for the revision
  history. Whitespace (including line breaks) is kept as its own token so the
  diff renders with the original layout.
  """

  @type op :: :eq | :ins | :del
  @type t :: [{op, String.t()}]

  @doc """
  Diffs `old` against `new`: a list of `{:eq | :ins | :del, text}` chunks.

      iex> FirestormWeb.Forums.Diff.words("a quick fox", "a slow fox")
      [eq: "a ", del: "quick", ins: "slow", eq: " fox"]
  """
  @spec words(String.t(), String.t()) :: t
  def words(old, new) do
    old
    |> tokenize()
    |> List.myers_difference(tokenize(new))
    |> Enum.map(fn {op, tokens} -> {op, Enum.join(tokens)} end)
  end

  defp tokenize(text), do: Regex.split(~r/\s+/u, text, include_captures: true, trim: true)
end
