defmodule FireflyWeb.MailingListTest do
  use FireflyWeb.ConnCase, async: false

  alias Firefly.{Accounts, SiteSettings}

  test "members turn mailing list mode on in their notification settings", %{conn: conn} do
    user = user_fixture()

    conn
    |> log_in_as(user)
    |> visit(~p"/settings/notifications")
    |> check("Mailing list mode: email me every new post (and let me reply by email)")
    |> uncheck("Except my own posts")
    |> click_button("#preferences-form button", "Save")
    |> assert_has("#flash-info", text: "Notification settings saved.")

    assert %{mailing_list_mode: true, mailing_list_no_echo: false} = Accounts.get_user!(user.id)
  end

  test "the option is gone when the site turns it off", %{conn: conn} do
    SiteSettings.update(%{"mailing_list_mode" => "false"}, admin_fixture())

    conn
    |> log_in_as(user_fixture())
    |> visit(~p"/settings/notifications")
    |> refute_has("#mailing-list-mode")
  end
end
