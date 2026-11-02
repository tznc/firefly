defmodule Mix.Tasks.Firefly.Gen.VapidKeys do
  @shortdoc "Generates a VAPID key pair for browser push notifications"

  @moduledoc """
  Generates a VAPID key pair for browser push notifications (see
  `FirestormWeb.WebPush`) and prints it as environment variables:

      mix firefly.gen.vapid_keys

  Set them, with `FIREFLY_VAPID_SUBJECT` (a contact URL such as
  `mailto:admin@example.com`), in the server's environment. Keep the
  private key secret, and keep the pair: changing it invalidates every
  browser's subscription.
  """
  use Mix.Task

  @impl true
  def run(_args) do
    {public, private} = FirestormWeb.WebPush.VAPID.generate_keys()

    Mix.shell().info("""
    FIREFLY_VAPID_PUBLIC_KEY=#{public}
    FIREFLY_VAPID_PRIVATE_KEY=#{private}
    FIREFLY_VAPID_SUBJECT=mailto:admin@example.com
    """)
  end
end
