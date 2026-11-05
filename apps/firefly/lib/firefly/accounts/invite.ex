defmodule Firefly.Accounts.Invite do
  @moduledoc """
  An invitation to join (see `Firefly.Accounts.Invites`): to one `email`
  address, or a link anyone can use up to `max_uses` times (optionally
  only with an address at `domain`). It lapses at `expires_at` or when
  revoked. Who redeemed it joins `role` (a group) and lands on `thread`,
  when set.
  """
  use Ecto.Schema
  use Firefly.Changeset

  alias Firefly.Accounts.{InviteRedemption, User}
  alias Firefly.Discussion.Thread
  alias Firefly.Groups.Role

  schema "invites" do
    field(:key, :string)
    field(:email, :string)
    field(:domain, :string)
    field(:max_uses, :integer, default: 1)
    field(:uses, :integer, default: 0)
    field(:expires_at, :utc_datetime)
    field(:revoked_at, :utc_datetime)
    field(:emailed_at, :utc_datetime)
    belongs_to(:invited_by, User)
    belongs_to(:role, Role)
    belongs_to(:thread, Thread)
    has_many(:redemptions, InviteRedemption)

    timestamps(type: :naive_datetime_usec)
  end

  @email ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @domain ~r/^[a-z0-9-]+(\.[a-z0-9-]+)+$/

  @doc "Casts the form's fields: `email`, or `max_uses` and `domain` for a link."
  def changeset(%__MODULE__{} = invite, attrs) do
    invite
    |> cast(attrs, [:email, :domain, :max_uses])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(
      :domain,
      &(&1 |> String.trim() |> String.trim_leading("@") |> String.downcase())
    )
    |> validate_format(:email, @email, message: "must be a valid email")
    |> validate_format(:domain, @domain, message: "must be a domain, like example.com")
    |> validate_link()
  end

  # An email invite is for one person; a link for up to 1000.
  defp validate_link(changeset) do
    if get_field(changeset, :email) do
      changeset |> put_change(:max_uses, 1) |> put_change(:domain, nil)
    else
      changeset
      |> validate_required(:max_uses)
      |> validate_number(:max_uses, greater_than: 0, less_than_or_equal_to: 1000)
    end
  end

  @doc "Whether it's sent to an email address (else it's a link)."
  def email?(%__MODULE__{email: email}), do: not is_nil(email)

  @doc "Why it can't be redeemed now (`:revoked`, `:expired`, `:used_up`), or nil."
  def problem(%__MODULE__{} = invite) do
    cond do
      invite.revoked_at -> :revoked
      DateTime.after?(DateTime.utc_now(), invite.expires_at) -> :expired
      invite.uses >= invite.max_uses -> :used_up
      true -> nil
    end
  end
end
