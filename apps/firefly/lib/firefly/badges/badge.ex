defmodule Firefly.Badges.Badge do
  @moduledoc """
  A badge (see `Firefly.Badges`): a `name`, `description`, `icon` (a
  `hero-*` icon name), `badge_type` (`gold`, `silver` or `bronze`), a
  `grouping` it's listed under, and switches: `enabled` (granted and
  shown), `allow_title` (holders may show it as their title),
  `multiple_grant` (granted once per post rather than once) and `listable`
  (on the badges page). `system` badges are defined by code.
  """

  use Ecto.Schema
  use Firefly.Changeset

  @types ~w(gold silver bronze)
  @groupings ~w(getting_started community posting trust_level other)

  # The icons a badge may use: written out here so the stylesheet build
  # (which scans the source for icon classes) includes them.
  @icons ~w(hero-star hero-trophy hero-sparkles hero-heart hero-fire hero-bolt hero-light-bulb
            hero-academic-cap hero-shield-check hero-hand-raised hero-hand-thumb-up hero-gift
            hero-rocket-launch hero-check-circle hero-chat-bubble-left-right hero-at-symbol
            hero-link hero-pencil hero-identification hero-cake hero-flag hero-beaker
            hero-code-bracket hero-globe-alt hero-musical-note hero-puzzle-piece)

  schema "badges" do
    field(:name, :string)
    field(:description, :string, default: "")
    field(:icon, :string, default: "hero-star")
    field(:badge_type, :string, default: "bronze")
    field(:grouping, :string, default: "other")
    field(:enabled, :boolean, default: true)
    field(:allow_title, :boolean, default: false)
    field(:multiple_grant, :boolean, default: false)
    field(:listable, :boolean, default: true)
    field(:system, :boolean, default: false)
    # How many members hold it, when a listing counts them.
    field(:grant_count, :integer, virtual: true, default: 0)

    timestamps(type: :utc_datetime)
  end

  def types, do: @types
  def groupings, do: @groupings
  def icons, do: @icons

  @doc "A grouping's heading."
  def grouping_label("getting_started"), do: "Getting started"
  def grouping_label("community"), do: "Community"
  def grouping_label("posting"), do: "Posting"
  def grouping_label("trust_level"), do: "Trust level"
  def grouping_label("other"), do: "Other"

  @doc "A custom badge's fields (admins)."
  def changeset(%__MODULE__{} = badge, attrs) do
    badge
    |> cast(attrs, [
      :name,
      :description,
      :icon,
      :badge_type,
      :grouping,
      :enabled,
      :allow_title,
      :multiple_grant,
      :listable
    ])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :icon])
    |> validate_length(:name, max: 60)
    |> validate_length(:description, max: 500)
    |> validate_inclusion(:icon, @icons)
    |> validate_inclusion(:badge_type, @types)
    |> validate_inclusion(:grouping, @groupings)
    |> unique_constraint(:name, name: :badges_lower_name_index)
  end

  @doc "What admins may change on a system badge: whether it's on, a title, listed."
  def system_changeset(%__MODULE__{} = badge, attrs),
    do: cast(badge, attrs, [:enabled, :allow_title, :listable])
end
