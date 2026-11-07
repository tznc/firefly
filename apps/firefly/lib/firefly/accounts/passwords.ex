defmodule Firefly.Accounts.Passwords do
  @moduledoc """
  Checks on a new password (registration, password reset), on top of the
  length rules in `Firefly.Accounts.User`:

    * **Strength**: [zxcvbn](https://github.com/techgaun/zxcvbn-elixir)
      scores it 0 (guessable in moments) to 4; below the
      `min_password_score` setting (default 2) it's refused. The member's
      username and email count as words an attacker would try. The forms
      show the score as they type (`strength/2`).
    * **Breaches**: with the `check_breached_passwords` setting (on by
      default), Have I Been Pwned's Pwned Passwords tells whether it
      appeared in a breach, by k-anonymity: only the first 5 hex
      characters of its SHA-1 leave the server, and the match is made here
      against the suffixes that come back. The request goes through the
      guarded outbound client (`Firefly.Rendering.LinkPreviews.Fetcher`:
      public addresses only) with a 3 second limit. If the service can't be
      reached the password is accepted (fail open) and a warning logged.
  """

  require Logger

  alias Firefly.SiteSettings
  alias Firefly.Rendering.LinkPreviews.Fetcher

  @labels %{0 => "very weak", 1 => "weak", 2 => "fair", 3 => "good", 4 => "strong"}

  @doc """
  How strong `password` is: `%{score: 0..4, label, warning}` (a
  `warning` from zxcvbn, or nil). `words` are other things an attacker
  knows (username, email). Only the first 72 characters count, as for
  bcrypt.
  """
  def strength(password, words \\ [])

  def strength(password, words) when is_binary(password) and password != "" do
    if String.valid?(password), do: score(password, words), else: strength(nil, words)
  end

  def strength(_password, _words), do: %{score: 0, label: @labels[0], warning: nil}

  defp score(password, words) do
    words = Enum.filter(words, &(is_binary(&1) and &1 != "" and String.valid?(&1)))

    password = String.slice(password, 0, 72)

    case zxcvbn(password, words) do
      %{score: score, feedback: feedback} ->
        %{score: score, label: @labels[score], warning: blank_to_nil(feedback[:warning])}

      :error ->
        score = brute_force_score(password)
        %{score: score, label: @labels[score], warning: nil}
    end
  end

  # zxcvbn 0.3.0 raises on some non-ASCII passwords (found by the property
  # tests): those get the brute-force estimate instead.
  defp zxcvbn(password, words) do
    ZXCVBN.zxcvbn(password, words)
  rescue
    error ->
      Logger.debug("zxcvbn failed: #{Exception.message(error)}")
      :error
  end

  # zxcvbn's own guess thresholds, for guesses = alphabet ^ length.
  defp brute_force_score(password) do
    graphemes = String.graphemes(password)

    alphabet =
      [
        {~r/[a-z]/, 26},
        {~r/[A-Z]/, 26},
        {~r/[0-9]/, 10},
        {~r/[^a-zA-Z0-9]/u, 100}
      ]
      |> Enum.filter(fn {pattern, _size} -> Regex.match?(pattern, password) end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.sum()

    log10_guesses = length(Enum.uniq(graphemes)) * :math.log10(max(alphabet, 2))

    cond do
      log10_guesses < 3 -> 0
      log10_guesses < 6 -> 1
      log10_guesses < 8 -> 2
      log10_guesses < 10 -> 3
      true -> 4
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  @doc """
  Adds an error to `changeset`'s `:password` change when it scores below
  `min_password_score` (see `strength/2`; `words` likewise). Cheap: forms
  run it as members type.
  """
  def validate_strength(%Ecto.Changeset{} = changeset, words) do
    # One complaint at a time: a password too short or long says so first.
    password =
      if not Keyword.has_key?(changeset.errors, :password),
        do: Ecto.Changeset.get_change(changeset, :password)

    case password do
      password when is_binary(password) and password != "" ->
        if strength(password, words).score < SiteSettings.get("min_password_score"),
          do:
            Ecto.Changeset.add_error(
              changeset,
              :password,
              "is too easy to guess: add words or make it longer",
              validation: :strength
            ),
          else: changeset

      _none ->
        changeset
    end
  end

  @doc """
  Adds an error to a valid `changeset`'s `:password` change when it
  appeared in a breach (see the module doc). Only when saving: it asks a
  remote service.
  """
  def validate_not_breached(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  def validate_not_breached(%Ecto.Changeset{} = changeset) do
    password = Ecto.Changeset.get_change(changeset, :password)

    if is_binary(password) and SiteSettings.get("check_breached_passwords") and
         breached?(password),
       do:
         Ecto.Changeset.add_error(
           changeset,
           :password,
           "has appeared in a data breach (haveibeenpwned.com): choose another",
           validation: :breached
         ),
       else: changeset
  end

  @doc """
  Whether Pwned Passwords knows `password` from a breach; false when it
  can't be asked (see the module doc).
  """
  def breached?(password) do
    case pwned_count(password) do
      {:ok, count} ->
        count > 0

      {:error, :off} ->
        false

      {:error, reason} ->
        Logger.warning("Pwned Passwords check skipped: #{inspect(reason)}")
        false
    end
  end

  @doc """
  How many times `password` appears in Pwned Passwords: `{:ok, count}` or
  `{:error, reason}` (off in this deployment, unreachable, a bad answer).
  """
  # Sobelow: SHA-1 is what the Pwned Passwords range API indexes by; it
  # never stores or protects the password here.
  # sobelow_skip ["Crypto.WeakHash"]
  def pwned_count(password) do
    hash = Base.encode16(:crypto.hash(:sha, password), case: :upper)
    <<prefix::binary-5, suffix::binary>> = hash

    with {:ok, base} <- base_url(),
         {:ok, %{body: body}} <-
           Fetcher.get(base <> prefix,
             types: ["text/plain"],
             max_bytes: 2_000_000,
             deadline: 3_000
           ) do
      {:ok, count(body, suffix)}
    end
  end

  # Tests point it at a local stub; nil turns it off (the test default).
  defp base_url do
    case Keyword.fetch(Application.get_env(:firefly, __MODULE__, []), :pwned_passwords_url) do
      {:ok, nil} -> {:error, :off}
      {:ok, url} -> {:ok, url}
      :error -> {:ok, "https://api.pwnedpasswords.com/range/"}
    end
  end

  defp count(body, suffix) do
    body
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.find_value(0, fn line ->
      with [^suffix, count] <- String.split(line, ":"),
           {count, _rest} <- Integer.parse(count) do
        count
      else
        _other -> nil
      end
    end)
  end
end
