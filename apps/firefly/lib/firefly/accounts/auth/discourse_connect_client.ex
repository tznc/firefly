defmodule Firefly.Accounts.Auth.DiscourseConnectClient do
  @moduledoc """
  A site that logs people in through Firefly as its DiscourseConnect
  provider (see `Firefly.Accounts.Auth.DiscourseConnectProvider`): its name,
  the secret its requests and our answers are signed with, and the hosts
  it may send people back to.
  """

  use Ecto.Schema

  use Firefly.Changeset

  schema "discourse_connect_clients" do
    field(:name, :string)
    field(:secret, Firefly.Encrypted.Binary, redact: true)
    field(:allowed_hosts, {:array, :string}, default: [])
    # The form's `allowed_hosts`, one per line or comma-separated.
    field(:hosts, :string, virtual: true)

    timestamps(type: :utc_datetime)
  end

  def changeset(client, attrs) do
    client
    |> cast(attrs, [:name, :secret, :hosts])
    |> put_hosts()
    |> validate_required([:name, :secret])
    |> validate_length(:name, max: 100)
    |> validate_length(:secret, min: 16, max: 255)
    |> validate_length(:allowed_hosts, min: 1, message: "needs at least one host")
  end

  defp put_hosts(changeset) do
    case get_change(changeset, :hosts) do
      nil ->
        changeset

      hosts ->
        hosts = hosts |> String.split([",", "\n", " "], trim: true) |> Enum.map(&normalize/1)

        if Enum.all?(hosts, &host?/1),
          do: put_change(changeset, :allowed_hosts, Enum.uniq(hosts)),
          else: add_error(changeset, :hosts, "must be host names, like forum.example.com")
    end
  end

  defp normalize(host), do: host |> String.trim() |> String.downcase()

  defp host?(host), do: Regex.match?(~r/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/, host)
end
