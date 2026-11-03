defmodule Firefly.AI.FeatureSetting do
  @moduledoc """
  How an AI feature (see `Firefly.AI.features/0`) is set up: whether it's
  on, the provider serving it, and whether only staff may use it. A
  feature without a row is off.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Firefly.AI.ProviderConfig

  @primary_key {:feature, :string, autogenerate: false}
  schema "ai_features" do
    belongs_to(:provider, ProviderConfig)
    field(:enabled, :boolean, default: false)
    field(:staff_only, :boolean, default: false)

    timestamps(type: :naive_datetime_usec)
  end

  def changeset(%__MODULE__{} = setting, attrs) do
    setting
    |> cast(attrs, [:provider_id, :enabled, :staff_only])
    |> foreign_key_constraint(:provider_id)
    |> validate_provider()
  end

  defp validate_provider(changeset) do
    if get_field(changeset, :enabled) and is_nil(get_field(changeset, :provider_id)),
      do: add_error(changeset, :provider_id, "pick a provider to turn the feature on"),
      else: changeset
  end
end
