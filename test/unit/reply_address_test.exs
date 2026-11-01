defmodule FirestormWeb.ReplyAddressTest do
  use ExUnit.Case, async: true

  alias FirestormWeb.ReplyAddress

  test "round-trips a thread and user" do
    address = ReplyAddress.address(%{id: 12}, %{id: 34})
    assert address =~ ~r/\Areply\+12-34-[a-z2-7]{24}@reply\.firefly\.tznc\.dev\z/
    assert {:ok, 12, 34} = ReplyAddress.verify("Firefly <#{address}>")
  end

  test "rejects tampering with the thread or user" do
    address = ReplyAddress.address(%{id: 12}, %{id: 34})

    assert :error = ReplyAddress.verify(String.replace(address, "+12-", "+13-"))
    assert :error = ReplyAddress.verify(String.replace(address, "-34-", "-35-"))
    assert :error = ReplyAddress.verify(nil)
  end
end
