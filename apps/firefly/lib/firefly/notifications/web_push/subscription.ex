defmodule Firefly.Notifications.WebPush.Subscription do
  @moduledoc """
  A browser's push subscription (see `Firefly.Notifications.WebPush`): the push
  service `endpoint` to POST to, the browser's `p256dh` public key and
  `auth` secret (base64url) to encrypt for, the browser it came from, and
  when a push last got through.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    belongs_to(:user, Firefly.Accounts.User)
    field(:endpoint, :string)
    field(:p256dh, :string)
    field(:auth, Firefly.Encrypted.Binary, redact: true)
    field(:user_agent, :string)
    field(:last_used_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  def changeset(%__MODULE__{} = subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :user_agent])
    |> update_change(:user_agent, &String.slice(&1, 0, 255))
    |> validate_required([:endpoint, :p256dh, :auth])
    |> validate_length(:endpoint, max: 2000)
    |> validate_change(:endpoint, fn :endpoint, url ->
      # Pushes go only to HTTPS push services.
      case URI.parse(url) do
        %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> []
        _other -> [endpoint: "must be an https URL"]
      end
    end)
    |> validate_key(:p256dh, 65)
    |> validate_key(:auth, 16)
  end

  defp validate_key(changeset, field, size) do
    validate_change(changeset, field, fn ^field, value ->
      case value |> String.trim_trailing("=") |> Base.url_decode64(padding: false) do
        {:ok, key} when byte_size(key) == size -> []
        _invalid -> [{field, "is invalid"}]
      end
    end)
  end
end
