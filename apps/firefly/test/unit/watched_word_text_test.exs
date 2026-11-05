defmodule Firefly.WatchedWordTextTest do
  @moduledoc "Regression tests for watched words Firefly.ModerationPropertyTest found mishandled."
  use ExUnit.Case, async: true

  alias Firefly.Moderation.WatchedWord

  # String.length/1 raises on a pictograph followed by a byte that isn't
  # UTF-8, so the length checks raised instead of refusing it.
  test "a word or replacement that isn't UTF-8 is refused, not a crash" do
    bad = "©" <> <<0xA5>>

    for {field, attrs} <- [
          word: %{word: bad, action: "block"},
          replacement: %{word: "spam", action: "replace", replacement: bad}
        ] do
      changeset = WatchedWord.changeset(%WatchedWord{}, attrs)
      refute changeset.valid?
      assert {"is not valid text", _} = changeset.errors[field]
    end
  end
end
