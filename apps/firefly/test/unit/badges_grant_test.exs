defmodule Firefly.BadgesGrantTest do
  @moduledoc "Regression tests for grants Firefly.BadgesPropertyTest found mishandled."
  use Firefly.DataCase

  import Firefly.Fixtures

  alias Firefly.Badges

  # A multiple badge is granted once per post (the unique index); granting
  # it by hand, with no post, a second time raised a constraint error.
  test "a multiple badge granted by hand twice is refused the second time" do
    admin = admin_fixture()
    user = user_fixture()
    {:ok, badge} = Badges.create_badge(%{name: "Helper", multiple_grant: true}, admin)

    assert {:ok, _} = Badges.grant(badge, user, admin)
    assert Badges.grant(badge, user, admin) == {:error, :already_granted}
    assert Badges.holds?(user, badge)
  end
end
