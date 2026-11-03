defmodule Firefly do
  @moduledoc """
  The domain's shared kernel: the repo, the port to the web interface
  (`Firefly.Endpoint`, `Firefly.URLs`), the mailer, rate limits, local
  times and job bookkeeping, used by every context.

  ## Bounded contexts

  The rest of the domain is split into bounded contexts, each a top-level
  [boundary](https://hexdocs.pm/boundary) whose root module is its facade:

  | Context | What |
  | --- | --- |
  | `Firefly.Accounts` | users, registration, login (password, social, SSO, magic links), 2FA and passkeys, password reset, confirmation, ignores, profiles, account export and deletion |
  | `Firefly.Discussion` | categories, threads, posts, likes, edits, wiki posts, read tracking, thread lists, tags, drafts, bookmarks, polls, solved, quotes, mentions, search |
  | `Firefly.Messaging` | private messages and group inboxes |
  | `Firefly.Moderation` | the posting gate, flags, the review queue, penalties, the staff log, thread timers and topic tools |
  | `Firefly.Notifications` | notifications and their fan-out, notification levels, emails, digests, browser push |
  | `Firefly.Groups`, `Firefly.TrustLevels`, `Firefly.Badges`, `Firefly.Directory` | groups, trust levels, badges, the user directory |
  | `Firefly.Uploads`, `Firefly.Rendering` | uploaded files; Markdown/BBCode, emoji, embeds and link previews |
  | `Firefly.SiteSettings` | site settings |
  | `Firefly.Analytics` | first-party traffic counts: page views, topic views, referrers, link clicks |
  | `Firefly.Reports` | the admin dashboard's overview and reports |
  | `Firefly.Backups` | backups and restores, read-only mode |
  | `Firefly.Upgrades` | the running version, the daily check for new releases, pending migrations |
  | `Firefly.Embedding` | topics as comments on other sites' pages (embeddable hosts, the embed feed) |
  | `Firefly.Chat` | real-time chat: channels, direct messages, threads, unread tracking |
  | `Firefly.AI` | AI model providers (pluggable adapters), per-feature provider selection, quotas and the usage log |
  | `Firefly.Plugins` (with `Firefly.Plugin`) | the plugin API, hook runner, host functions and installed plugins |

  A context's public API is its root module plus the modules its `use
  Boundary` exports (schemas and feature modules); everything else in it is
  internal. The web and plugin apps are boundaries that depend on the
  contexts, so the `boundary` compiler rejects any use of an internal
  module there. Contexts call each other in both directions, which
  `boundary` can't check without forbidding the cycles, so
  `Firefly.BoundariesTest` checks those references instead.
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [Repo, Endpoint, URLs, Mailer, RateLimit, LocalTime, JobRuns]
end
