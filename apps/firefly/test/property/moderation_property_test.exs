defmodule Firefly.ModerationPropertyTest do
  @moduledoc """
  Properties of `Firefly.Moderation`'s watched words: any word staff can
  add, wildcard or regex, matches without raising and quickly, whatever
  members write; censoring is idempotent and keeps the text's length;
  rendering a run of text keeps all of it; and the posting gate agrees
  with itself.
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.Moderation.{Posting, WatchedWord, WatchedWords}

  # Words staff might watch: plain, with wildcards, and regexes, the
  # catastrophic kind included.
  defp word do
    one_of([
      map(string(:alphanumeric, min_length: 1, max_length: 8), &%{word: &1, regex: false}),
      map(
        {string(:alphanumeric, min_length: 1, max_length: 5), member_of(["*", "", "*x", "x*"]),
         member_of(["", "*"])},
        fn {w, a, b} -> %{word: b <> w <> a, regex: false} end
      ),
      map(adversarial_text(3), &%{word: &1, regex: false}),
      map(
        member_of([
          "(a+)+$",
          "(a|aa)+b",
          "(a|a)*c",
          "(.*a){12}",
          "^(\\w+\\s?)+$",
          "(x+x+)+y",
          "\\bspam\\w*",
          "c[a@]t",
          "(?i)foo|bar",
          "\\d{3}-\\d{4}",
          "(?<=a)b",
          "\\b",
          "[",
          "a{1,99999}",
          "(?:)",
          "\\p{L}+"
        ]),
        &%{word: &1, regex: true}
      )
    ])
  end

  defp text do
    one_of([
      adversarial_text(),
      map(integer(10..3_000), &(String.duplicate("a", &1) <> "!")),
      map(integer(10..500), &(String.duplicate("x", &1) <> "y" <> String.duplicate(" a", &1))),
      long_string(5_000)
    ])
  end

  # The words as WatchedWords holds them: those the changeset accepts.
  defp matchers(words, action) do
    words
    |> Enum.map(
      &WatchedWord.changeset(
        %WatchedWord{},
        Map.merge(&1, %{action: action, replacement: replacement(action)})
      )
    )
    |> Enum.filter(& &1.valid?)
    |> Enum.map(&Ecto.Changeset.apply_changes/1)
    |> WatchedWords.compile()
  end

  defp replacement("replace"), do: "[redacted]"
  defp replacement("link"), do: "https://example.com/rules"
  defp replacement("tag"), do: "flagged"
  defp replacement(_action), do: nil

  # A slow match stops at a limit (a couple of hundred milliseconds at
  # worst for Erlang's default); this bounds each call well under it.
  @fast_ms 1_000

  defp timed(fun) do
    {microseconds, result} = :timer.tc(fun)
    {div(microseconds, 1000), result}
  end

  describe "watched words" do
    property "the changeset never raises" do
      check all(
              word <- one_of([any_text(), map(word(), & &1.word)]),
              regex <- boolean(),
              action <- one_of([member_of(WatchedWord.actions()), adversarial_text(2)]),
              replacement <- one_of([constant(nil), any_text(), url()]),
              max_runs: runs(200)
            ) do
        assert %Ecto.Changeset{} =
                 WatchedWord.changeset(%WatchedWord{}, %{
                   word: word,
                   regex: regex,
                   action: action,
                   replacement: replacement
                 })
      end
    end

    property "matching, censoring and rendering never raise and finish quickly" do
      check all(
              words <- list_of(word(), min_length: 1, max_length: 4),
              text <- text(),
              max_runs: runs(60)
            ) do
        censor = matchers(words, "censor")
        replace = matchers(words, "replace")
        link = matchers(words, "link")
        all = Map.merge(censor, Map.merge(replace, link))

        for fun <- [
              fn -> WatchedWords.censor(text, censor) end,
              fn -> WatchedWords.render_text(text, true, all) end,
              fn -> WatchedWords.render_text(text, false, all) end
            ] do
          {ms, _result} = timed(fun)
          assert ms < @fast_ms, "took #{ms} ms for #{inspect(Enum.map(words, & &1.word))}"
        end
      end
    end

    property "censoring is idempotent and keeps the text's length" do
      check all(
              words <- list_of(word(), min_length: 1, max_length: 4),
              text <- adversarial_text(),
              max_runs: runs(200)
            ) do
        # Regexes may match the mask itself; plain and wildcard words can't.
        matchers = matchers(Enum.reject(words, & &1.regex), "censor")
        once = WatchedWords.censor(text, matchers)
        assert WatchedWords.censor(once, matchers) == once

        # The mask has a ■ per character matched. A word that starts with
        # a combining mark matches inside a character (" ́") and its mask
        # splits it, so only other words keep the count of characters.
        if not Enum.any?(words, &(&1.word =~ ~r/\A\p{M}/u)),
          do: assert(String.length(once) == String.length(text))
      end
    end

    property "rendering keeps every bit of text outside the words" do
      check all(
              words <- list_of(word(), min_length: 1, max_length: 3),
              text <- adversarial_text(),
              max_runs: runs(200)
            ) do
        matchers = matchers(Enum.reject(words, & &1.regex), "link")

        parts = WatchedWords.render_text(text, true, matchers)

        joined =
          Enum.map_join(parts, fn
            {:text, t} -> t
            {:link, t, _url} -> t
          end)

        assert joined == text

        for {:link, linked, url} <- parts do
          assert url == "https://example.com/rules"
          assert linked != ""
        end
      end
    end
  end

  describe "the posting gate" do
    property "check/1 and message/1 agree, for any member" do
      check all(
              trust <- integer(0..4),
              confirmed? <- boolean(),
              max_runs: runs(20)
            ) do
        user = user_fixture(%{trust_level: trust})

        user =
          if confirmed?,
            do: user,
            else: Repo.update!(Ecto.Changeset.change(user, confirmed_at: nil))

        case Posting.check(user) do
          :ok -> :ok
          {:error, reason} -> assert is_binary(Posting.message(reason))
        end

        for action <- [:like, :flag, :chat, :new_conversation] do
          case Posting.check(user, action) do
            :ok -> :ok
            {:error, reason} -> assert is_binary(Posting.message(reason))
          end
        end
      end
    end
  end

  describe "deep fuzzing" do
    @describetag :fuzz
    @describetag timeout: :infinity

    property "matching stays total and fast" do
      check all(
              words <- list_of(word(), min_length: 1, max_length: 6),
              text <- one_of([text(), any_text()]),
              max_runs: fuzz_runs()
            ) do
        text = String.replace_invalid(text)
        all = Map.merge(matchers(words, "censor"), matchers(words, "link"))

        {ms, _} =
          timed(fn ->
            {WatchedWords.censor(text, all), WatchedWords.render_text(text, true, all)}
          end)

        assert ms < @fast_ms
      end
    end
  end
end
