defmodule FireflyWeb.Api.V1.UserJSON do
  @moduledoc "JSON representation of users (public fields only)."
  alias Firefly.Accounts.User
  alias Firefly.URLs

  def data(%User{} = user) do
    user
    |> Map.take([:id, :name, :username, :inserted_at, :updated_at])
    |> Map.put(:avatar_url, User.avatar_url(user))
  end

  @doc "A profile: the public fields plus what the profile shows."
  def profile(%User{} = user) do
    user
    |> data()
    |> Map.merge(Map.take(user, [:bio, :website, :location, :trust_level]))
    |> Map.put(:url, URLs.user_url(user))
  end

  @doc "The user themselves: their profile and preferences."
  def me(%User{} = user) do
    user
    |> profile()
    |> Map.merge(%{email: user.email, preferences: preferences(user)})
  end

  @preferences ~w(email_notifications allow_private_messages theme reply_level new_thread_level
                  hide_profile_activity hide_from_directory hide_profile digest_frequency
                  push_only_when_away mailing_list_mode mailing_list_no_echo)a

  @doc "The preference fields `PATCH /me/preferences` takes."
  def preference_fields, do: Enum.map(@preferences, &Atom.to_string/1)

  def preferences(%User{} = user), do: Map.take(user, @preferences)
end
