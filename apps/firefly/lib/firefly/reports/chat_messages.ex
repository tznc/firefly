defmodule Firefly.Reports.ChatMessages do
  @moduledoc false
  use Firefly.Reports.Report,
    id: "chat_messages",
    title: "Chat messages",
    description: "Chat messages sent per day, in channels and direct messages."

  @impl true
  def run(range),
    do:
      series(
        "chat_messages",
        "Chat messages",
        daily(count_by_day("chat_messages", :inserted_at, range), range)
      )
end
