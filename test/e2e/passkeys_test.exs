defmodule FirestormWeb.E2E.PasskeysTest do
  use FirestormWeb.E2ECase, async: false

  # Chromium's virtual authenticator (DevTools protocol), standing in for a
  # phone or laptop: it holds discoverable credentials and verifies the
  # user without asking.
  defp add_virtual_authenticator(conn) do
    unwrap(conn, fn %{context_id: context_id, page_id: page_id} ->
      %{result: %{session: %{guid: cdp}}} =
        PlaywrightEx.send(
          %{guid: context_id, method: "newCDPSession", params: %{"page" => %{"guid" => page_id}}},
          timeout: 5_000
        )

      cdp_send(cdp, "WebAuthn.enable", %{})

      cdp_send(cdp, "WebAuthn.addVirtualAuthenticator", %{
        "options" => %{
          "protocol" => "ctap2",
          "transport" => "internal",
          "hasResidentKey" => true,
          "hasUserVerification" => true,
          "isUserVerified" => true,
          "automaticPresenceSimulation" => true
        }
      })
    end)
  end

  defp cdp_send(cdp, method, params) do
    %{result: _} =
      PlaywrightEx.send(
        %{guid: cdp, method: :send, params: %{"method" => method, "params" => params}},
        timeout: 5_000
      )
  end

  test "a member adds a passkey, then logs in with it alone", %{conn: conn} do
    member_fixture("ada")

    conn
    |> visit("/login")
    |> add_virtual_authenticator()
    |> log_in("ada")
    |> visit("/settings/security")
    |> assert_has("[data-phx-main].phx-connected")
    |> fill_in("New passkey's name", with: "Laptop")
    |> click_button("Add a passkey")
    |> assert_has("#flash-info", text: "Passkey added.")
    |> assert_has("#passkeys input[value=Laptop]")
    |> click_link("Log out")
    |> assert_has("nav a", text: "Log in")
    |> visit("/login")
    |> assert_has("[data-phx-main].phx-connected")
    |> click_button("Use a passkey")
    |> assert_path("/")
    |> assert_has("nav a", text: "Your profile")
  end
end
