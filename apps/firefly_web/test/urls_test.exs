defmodule FireflyWeb.URLsTest do
  # The domain builds its links without the router (see Firefly.URLs): they
  # must be exactly what the verified routes give.
  use FireflyWeb.ConnCase, async: true

  alias Firefly.URLs

  test "the domain's URLs are the router's" do
    token = "SFMyNTY.g2gDYQFuBgB-ZXhhbXBsZQ.a_b-c"
    group = %{name: "Ünïcode crew/50% #1"}

    assert URLs.confirmation_url(token) == url(~p"/confirm/#{token}")
    assert URLs.password_reset_url(token) == url(~p"/reset-password/#{token}")
    assert URLs.magic_link_url(token) == url(~p"/login/email/#{token}")
    assert URLs.digest_unsubscribe_url(token) == url(~p"/email/unsubscribe/#{token}")
    assert URLs.notification_settings_url() == url(~p"/settings/notifications")
    assert URLs.security_settings_url() == url(~p"/settings/security")
    assert URLs.notifications_url() == url(~p"/notifications")
    assert URLs.user_url(%{id: 7}) == url(~p"/users/7")
    assert URLs.invite_url("aB-_1") == url(~p"/invites/aB-_1")
    assert URLs.saml_acs_url() == url(~p"/auth/saml/acs")
    assert URLs.saml_metadata_url() == url(~p"/saml/metadata")
    assert URLs.group_url(group) == url(~p"/groups/#{group.name}")
    assert URLs.group_url(group, "requests") == url(~p"/groups/#{group.name}/requests")
    assert URLs.badge_url(%{id: 3}) == url(~p"/badges/3")
    assert URLs.category_url(%{id: 4}) == url(~p"/categories/4")
    assert URLs.conversation_url(%{id: 5}) == url(~p"/messages/5")
    assert URLs.chat_channel_url(%{id: 6, slug: "general"}) == url(~p"/chat/c/general/6")
    assert URLs.chat_channel_url(%{id: 8, slug: nil}) == url(~p"/chat/c/dm/8")
    assert URLs.thread_url(%{id: 2, category_id: 1}) == url(~p"/categories/1/threads/2")
  end
end
