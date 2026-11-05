defmodule Firefly.PenaltyDatesTest do
  @moduledoc "Regression tests for penalty parameters Firefly.ModerationActionsPropertyTest found mishandled."
  # Sync: it makes an admin (the shared admin role).
  use Firefly.DataCase, async: false

  import Firefly.Fixtures

  alias Firefly.Moderation.Penalties

  test "an end date that isn't a string is refused, not a crash" do
    admin = admin_fixture()
    user = user_fixture()

    # As the API passes JSON through.
    for until <- [[], %{}, 20_270_101, nil] do
      assert {:error, :invalid_date} =
               Penalties.penalize(:silence, user, admin, %{
                 "duration" => "date",
                 "until" => until,
                 "reason" => "Spam."
               })
    end
  end
end
