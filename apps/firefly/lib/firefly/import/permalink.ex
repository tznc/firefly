defmodule Firefly.Import.Permalink do
  @moduledoc """
  An old site's URL (`url`: its path and maybe query, without the leading
  slash, e.g. `t/welcome/12` or `viewtopic.php?t=12`) and what it now
  leads to: exactly one of a thread, post, category, user, tag or an
  external URL. Importers make them (see `Firefly.Import`); the web app
  redirects requests for them.
  """

  use Ecto.Schema

  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Category, Post, Tag, Thread}

  schema "permalinks" do
    field(:url, :string)
    field(:source, :string)
    field(:external_url, :string)
    belongs_to(:thread, Thread)
    belongs_to(:post, Post)
    belongs_to(:category, Category)
    belongs_to(:user, User)
    belongs_to(:tag, Tag)

    timestamps(type: :naive_datetime_usec)
  end

  @doc "The fields that can be its target."
  def targets, do: [:thread_id, :post_id, :category_id, :user_id, :tag_id, :external_url]
end
