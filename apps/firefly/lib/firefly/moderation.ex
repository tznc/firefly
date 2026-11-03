defmodule Firefly.Moderation do
  @moduledoc """
  The Moderation context: keeping the forum healthy.

  Its public modules:

    * `Firefly.Moderation.Posting` - whether a member may post right now
      (penalties, slow mode, approval, spam checks), for web, API and email
    * `Firefly.Moderation.Flags` and `Review` - flags and the review queue
    * `Firefly.Moderation.Penalties` - silencing and suspending members
    * `Firefly.Moderation.StaffLog` - the audit trail of staff actions
    * `Firefly.Moderation.TopicTimers` and `TopicTools` - timed thread
      changes, and moving posts between threads
    * `Firefly.Moderation.BulkActions` - acting on many threads at once
    * `Firefly.Moderation.WatchedWords` - words that block, censor, queue,
      flag, replace, tag, silence or link
    * `Firefly.Moderation.Akismet` - spam checks of new content with Akismet
    * `Firefly.Moderation.Screening` - screened emails, IPs and URLs that
      block sign-ups and posts
    * the schemas `Flag`, `StaffAction`, `ThreadTimer`, `WatchedWord` and
      `AkismetCheck`, `ScreenedItem`

  Its other modules (`SpamGuard`) are internal.
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [
      Posting,
      Flags,
      Review,
      Penalties,
      StaffLog,
      TopicTimers,
      TopicTools,
      BulkActions,
      Flag,
      ThreadTimer,
      SpamGuard,
      WatchedWords,
      WatchedWord,
      Akismet,
      AkismetCheck,
      Screening,
      ScreenedItem
    ]
end
