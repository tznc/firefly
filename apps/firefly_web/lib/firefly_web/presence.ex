defmodule FireflyWeb.Presence do
  @moduledoc """
  Presence in chat channels (see `FireflyWeb.ChatLive`): each open channel
  page is tracked on the channel's `Firefly.Chat.presence_topic/1`, keyed
  by user id, so a channel shows who's there across nodes.
  """
  use Phoenix.Presence, otp_app: :firefly_web, pubsub_server: Firefly.PubSub
end
