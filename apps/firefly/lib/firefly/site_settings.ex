defmodule Firefly.SiteSettings do
  @moduledoc """
  Site settings admins edit at runtime (at `/staff/settings`), stored in
  `forums_site_settings` as key/value rows.

  The settings, their types and defaults are defined here; a row exists only
  for a setting an admin changed, so every default is the behavior the site
  had before settings existed (two defaults come from the deployment's
  config: `FIREFLY_TAGS_ADMIN_ONLY` and the `:post` rate limit).

  Reads are served from `:persistent_term`. An update clears the cache on
  this node at once, and on every node through PubSub (see
  `Firefly.SiteSettings.Cache`), so the next read loads the new values
  (clearing starts a new cache generation, so a read racing the update
  can't put old values back).
  The cache is off in tests (`config :firefly, :site_settings_cache`),
  where each test's settings live in its own database transaction.
  """

  use Boundary, top_level?: true, check: [out: false], exports: []

  import Ecto.Query

  alias Firefly.{RateLimit, Repo}
  alias Firefly.Moderation.StaffLog
  alias Firefly.SiteSettings.SiteSetting

  @pubsub Firefly.PubSub
  @topic "site_settings"
  @cache_key {__MODULE__, :values}
  @generation_key {__MODULE__, :generation}

  @doc """
  Every setting, in display order: `key`, `section`, `type` (`:string`,
  `:text`, `:email`, `:boolean`, `:integer` or `:select`), `label`, `help`,
  `default`, for integers `min`/`max`, for texts optionally `max_length`
  (500 characters by default), and for selects `options` (`{label, value}`
  pairs).
  """
  def definitions do
    [
      %{
        key: "title",
        section: "Site",
        type: :string,
        label: "Title",
        default: "Firefly",
        help: "The site's name: in the header, page titles and emails."
      },
      %{
        key: "description",
        section: "Site",
        type: :text,
        label: "Description",
        default: "",
        help: "Shown on the home page and to search engines. Blank: none."
      },
      %{
        key: "contact_email",
        section: "Site",
        type: :email,
        label: "Contact email",
        default: "",
        help: "Linked from the sidebar as the way to reach staff. Blank: none."
      },
      %{
        key: "allow_registrations",
        section: "Registration",
        type: :boolean,
        label: "Allow new registrations",
        default: true,
        help: "Off: nobody can create an account, with a password or a social login."
      },
      %{
        key: "invite_only",
        section: "Registration",
        type: :boolean,
        label: "Invite only",
        default: false,
        help:
          "On: only people with an invitation can create an account (with a password, a social login or single sign-on)."
      },
      %{
        key: "invite_expiry_days",
        section: "Registration",
        type: :integer,
        label: "Invitations expire after (days)",
        default: 30,
        min: 1,
        max: 365,
        help: "How long an invitation can be used."
      },
      %{
        key: "require_email_confirmation",
        section: "Registration",
        type: :boolean,
        label: "Require email confirmation",
        default: true,
        help:
          "Off: members can post without confirming their email. Email notifications still go only to confirmed addresses."
      },
      %{
        key: "passkeys",
        section: "Logins",
        type: :boolean,
        label: "Passkeys",
        default: true,
        help:
          "Members can add passkeys and log in with them alone (the device checks it's them, so no second factor is asked)."
      },
      %{
        key: "magic_links",
        section: "Logins",
        type: :boolean,
        label: "Email login links",
        default: true,
        help:
          "Members can log in with a one-time link emailed to their confirmed address (then their second factor, if they have one)."
      },
      %{
        key: "magic_link_signup",
        section: "Logins",
        type: :boolean,
        label: "Sign up by email link",
        default: false,
        help:
          "An address without an account gets a link that creates one (while registrations are open)."
      },
      %{
        key: "two_factor_sso_logins",
        section: "Logins",
        type: :boolean,
        label: "Two-factor after social and SSO logins",
        default: true,
        help:
          "On: members with two-factor authentication give their second factor after social and single sign-on logins too. Off: only after passwords and email links."
      },
      %{
        key: "enforce_two_factor_staff",
        section: "Logins",
        type: :boolean,
        label: "Require two-factor for staff",
        default: false,
        help: "Admins must set up two-factor authentication before they can use the site."
      },
      %{
        key: "discourse_connect_overrides_email",
        section: "Logins",
        type: :boolean,
        label: "Sync email from DiscourseConnect",
        default: false,
        help:
          "Each DiscourseConnect login sets the member's email to the provider's (confirmed unless it asks for activation)."
      },
      %{
        key: "discourse_connect_overrides_username",
        section: "Logins",
        type: :boolean,
        label: "Sync username from DiscourseConnect",
        default: false,
        help:
          "Each DiscourseConnect login renames the member to their username there (if it's free here)."
      },
      %{
        key: "discourse_connect_overrides_name",
        section: "Logins",
        type: :boolean,
        label: "Sync name from DiscourseConnect",
        default: false,
        help: "Each DiscourseConnect login sets the member's name to the provider's."
      },
      %{
        key: "discourse_connect_overrides_avatar",
        section: "Logins",
        type: :boolean,
        label: "Sync avatar from DiscourseConnect",
        default: false,
        help:
          "When the provider's avatar_url changes, it's fetched and becomes the member's avatar."
      },
      %{
        key: "discourse_connect_sync_staff",
        section: "Logins",
        type: :boolean,
        label: "Sync admins and moderators from DiscourseConnect",
        default: false,
        help:
          "The provider's admin and moderator flags add members to, or remove them from, the admin and moderator groups."
      },
      %{
        key: "discourse_connect_overrides_groups",
        section: "Logins",
        type: :boolean,
        label: "Sync groups from DiscourseConnect",
        default: false,
        help:
          "The provider's groups, add_groups and remove_groups set the member's groups (only groups that exist here)."
      },
      %{
        key: "new_user_max_links",
        section: "Spam and new users",
        type: :integer,
        label: "Links per post at trust level 0",
        default: 2,
        min: 0,
        max: 100,
        help: "How many links a new user's (trust level 0) post may contain."
      },
      %{
        key: "new_user_max_images",
        section: "Spam and new users",
        type: :integer,
        label: "Images per post at trust level 0",
        default: 1,
        min: 0,
        max: 100,
        help: "How many images a new user's post may embed."
      },
      %{
        key: "new_user_max_attachments",
        section: "Spam and new users",
        type: :integer,
        label: "Attachments per post at trust level 0",
        default: 0,
        min: 0,
        max: 100,
        help: "How many uploaded files (other than images) a new user's post may link."
      },
      %{
        key: "new_user_max_mentions",
        section: "Spam and new users",
        type: :integer,
        label: "Mentions per post at trust level 0",
        default: 2,
        min: 0,
        max: 100,
        help: "How many users a new user's post may @mention."
      },
      %{
        key: "max_mentions",
        section: "Spam and new users",
        type: :integer,
        label: "Mentions per post",
        default: 10,
        min: 0,
        max: 100,
        help: "How many users one post may @mention."
      },
      %{
        key: "posts_per_minute",
        section: "Spam and new users",
        type: :integer,
        label: "Posts per minute",
        default: RateLimit.configured_limit(:post),
        min: 1,
        max: 10_000,
        help: "New threads, replies and messages one user may post per minute."
      },
      %{
        key: "tags_admin_only",
        section: "Spam and new users",
        type: :boolean,
        label: "Only admins create tags",
        default: Application.get_env(:firefly, :tags_admin_only, false),
        help: "On: members can only use existing tags."
      },
      %{
        key: "approve_new_user_posts",
        section: "Spam and new users",
        type: :integer,
        label: "Posts needing approval",
        default: 0,
        min: 0,
        max: 100,
        help:
          "A new user's first this-many threads and replies wait in the review queue until staff approve them. 0: off."
      },
      %{
        key: "approve_unless_trust_level",
        section: "Spam and new users",
        type: :integer,
        label: "Approve posts below trust level",
        default: 0,
        min: 0,
        max: 4,
        help: "Threads and replies by members below this trust level wait for approval. 0: off."
      }
    ] ++ trust_level_definitions() ++ content_definitions()
  end

  # Thresholds for automatic promotion (see Firefly.TrustLevels), with
  # Discourse's defaults.
  defp trust_level_definitions do
    [
      tl(
        "min_trust_to_send_messages",
        "Trust level to send private messages",
        1,
        4,
        "Members below it can't start conversations (they can still reply)."
      ),
      tl("min_trust_to_flag", "Trust level to flag posts", 1, 4, "Members below it can't flag."),
      tl(
        "min_trust_to_invite",
        "Trust level to invite people",
        2,
        4,
        "Members below it can't send invitations (admins always can)."
      ),
      tl(
        "min_trust_to_edit_wiki",
        "Trust level to edit wiki posts",
        1,
        4,
        "Members below it can't edit others' wiki posts."
      ),
      tl(
        "tl1_requires_topics_entered",
        "Level 1: topics entered",
        5,
        10_000,
        "Threads a new user must open to become a basic user."
      ),
      tl(
        "tl1_requires_read_posts",
        "Level 1: posts read",
        30,
        100_000,
        "Posts a new user must read to become a basic user."
      ),
      tl(
        "tl2_requires_topics_entered",
        "Level 2: topics entered",
        20,
        10_000,
        "Threads a basic user must open to become a member."
      ),
      tl(
        "tl2_requires_read_posts",
        "Level 2: posts read",
        100,
        100_000,
        "Posts a basic user must read to become a member."
      ),
      tl(
        "tl2_requires_days_visited",
        "Level 2: days visited",
        15,
        10_000,
        "Days a basic user must visit on to become a member."
      ),
      tl(
        "tl2_requires_likes_received",
        "Level 2: likes received",
        1,
        10_000,
        "Likes a basic user must receive to become a member."
      ),
      tl(
        "tl2_requires_likes_given",
        "Level 2: likes given",
        1,
        10_000,
        "Likes a basic user must give to become a member."
      ),
      tl(
        "tl2_requires_topic_reply_count",
        "Level 2: topics replied to",
        3,
        10_000,
        "Others' threads a basic user must reply to to become a member."
      ),
      Map.put(
        tl(
          "tl3_time_period",
          "Level 3: period (days)",
          100,
          1_000,
          "The window the other level 3 requirements (except all-time ones) are counted in."
        ),
        :min,
        1
      ),
      tl(
        "tl3_requires_days_visited",
        "Level 3: days visited",
        50,
        1_000,
        "Days visited in the period."
      ),
      tl(
        "tl3_requires_topics_replied_to",
        "Level 3: topics replied to",
        10,
        10_000,
        "Others' threads replied to in the period."
      ),
      tl(
        "tl3_requires_topics_viewed",
        "Level 3: topics viewed (%)",
        25,
        100,
        "Share of the threads created in the period (at most 500) the member opened."
      ),
      tl(
        "tl3_requires_posts_read",
        "Level 3: posts read (%)",
        25,
        100,
        "Share of the posts made in the period (at most 20,000) the member read."
      ),
      tl(
        "tl3_requires_topics_viewed_all_time",
        "Level 3: topics viewed, all time",
        200,
        100_000,
        "Threads opened, ever."
      ),
      tl(
        "tl3_requires_posts_read_all_time",
        "Level 3: posts read, all time",
        500,
        1_000_000,
        "Posts read, ever."
      ),
      tl(
        "tl3_requires_max_flagged",
        "Level 3: most flagged posts",
        5,
        10_000,
        "At most this many of the member's posts had flags staff agreed with in the period."
      ),
      tl(
        "tl3_requires_likes_given",
        "Level 3: likes given",
        30,
        10_000,
        "Likes given in the period."
      ),
      tl(
        "tl3_requires_likes_received",
        "Level 3: likes received",
        20,
        10_000,
        "Likes received in the period."
      ),
      tl(
        "tl3_promotion_min_duration",
        "Level 3: grace period (days)",
        14,
        365,
        "A regular keeps level 3 at least this long before the review can demote them."
      )
    ]
  end

  defp tl(key, label, default, max, help) do
    %{
      key: key,
      section: "Trust levels",
      type: :integer,
      label: label,
      default: default,
      min: 0,
      max: max,
      help: help
    }
  end

  defp content_definitions do
    [
      %{
        key: "mailing_list_mode",
        section: "Email",
        type: :boolean,
        label: "Mailing list mode",
        default: true,
        help:
          "Members can choose to get every new post by email (and reply by email), instead of notification emails about posts."
      },
      %{
        key: "max_mailing_list_emails_per_day",
        section: "Email",
        type: :integer,
        label: "Mailing list emails per member per day",
        default: 100,
        min: 1,
        max: 10_000,
        help:
          "Posts beyond this many in a day aren't emailed to that member (they're still on the site)."
      },
      %{
        key: "digests_enabled",
        section: "Email",
        type: :boolean,
        label: "Digest emails",
        default: true,
        help:
          "Members who haven't visited in a while get a summary of popular threads, as often as they choose."
      },
      %{
        key: "default_digest_frequency",
        section: "Email",
        type: :select,
        options: Firefly.Notifications.Digests.frequency_options(),
        label: "Default digest frequency",
        default: "weekly",
        help: "For members who haven't chosen."
      },
      %{
        key: "max_tags_per_thread",
        section: "Content",
        type: :integer,
        label: "Tags per thread",
        default: 5,
        min: 0,
        max: 20,
        help: "How many tags a thread may have."
      },
      %{
        key: "edit_grace_minutes",
        section: "Content",
        type: :integer,
        label: "Edit window (minutes)",
        default: 0,
        min: 0,
        max: 525_600,
        help: "How long authors can edit their posts. 0: forever. Admins can always edit."
      },
      %{
        key: "flags_to_hide",
        section: "Content",
        type: :integer,
        label: "Flags to hide a post",
        default: 3,
        min: 1,
        max: 100,
        help: "A post flagged by this many members is hidden until staff review it."
      },
      %{
        key: "bbcode",
        section: "Content",
        type: :boolean,
        label: "BBCode",
        default: true,
        help:
          "Posts may use BBCode ([b], [quote], [url], [list], [spoiler]...) as well as Markdown."
      },
      %{
        key: "spoilers",
        section: "Content",
        type: :boolean,
        label: "Spoilers",
        default: true,
        help: "Text in >!...!< or [spoiler] is hidden until clicked."
      },
      %{
        key: "math",
        section: "Content",
        type: :boolean,
        label: "Math",
        default: true,
        help: "$...$ and $$...$$ are typeset as math (KaTeX)."
      },
      %{
        key: "footnotes",
        section: "Content",
        type: :boolean,
        label: "Footnotes",
        default: true,
        help: "[^1] references and [^1]: footnote text."
      },
      %{
        key: "max_upload_kb",
        section: "Uploads",
        type: :integer,
        label: "Largest upload (KB)",
        default: 10_240,
        min: 1,
        max: 102_400,
        help: "The largest file a member may attach."
      },
      %{
        key: "upload_quota_mb",
        section: "Uploads",
        type: :integer,
        label: "Upload space per member (MB)",
        default: 500,
        min: 0,
        max: 1_000_000,
        help:
          "How much a member may upload in all (each distinct file counted once). 0: no limit."
      },
      %{
        key: "max_image_dimension",
        section: "Uploads",
        type: :integer,
        label: "Largest image side (pixels)",
        default: 4096,
        min: 256,
        max: 16_384,
        help: "Bigger images are scaled down to fit when uploaded."
      },
      %{
        key: "orphan_upload_hours",
        section: "Uploads",
        type: :integer,
        label: "Keep unused uploads (hours)",
        default: 24,
        min: 1,
        max: 24 * 30,
        help: "Uploads no post, message or draft uses are deleted after this long."
      },
      %{
        key: "link_previews",
        section: "Link previews",
        type: :boolean,
        label: "Show link previews",
        default: true,
        help:
          "A link alone on its line shows as a card with the page's title, description and image (fetched by the server)."
      },
      %{
        key: "link_preview_hours",
        section: "Link previews",
        type: :integer,
        label: "Refresh previews after (hours)",
        default: 168,
        min: 1,
        max: 24 * 90,
        help: "How long a fetched preview is used before it's fetched again."
      },
      %{
        key: "plugin_egress_days",
        section: "Plugins",
        type: :integer,
        label: "Keep plugin network logs (days)",
        default: 14,
        min: 1,
        max: 365,
        help: "How long each plugin's log of outgoing requests is kept."
      },
      %{
        key: "analytics",
        section: "Analytics",
        type: :boolean,
        label: "Count traffic",
        default: true,
        help:
          "First-party counts of page views, topic views, referrers and link clicks (no cookies, no IP addresses kept, nothing sent to third parties)."
      },
      %{
        key: "backup_frequency_days",
        section: "Backups",
        type: :integer,
        label: "Back up every (days)",
        default: 0,
        min: 0,
        max: 30,
        help: "Automatic backups, every this many days. 0: off."
      },
      %{
        key: "backup_keep",
        section: "Backups",
        type: :integer,
        label: "Backups to keep",
        default: 5,
        min: 1,
        max: 100,
        help: "After each backup, older ones beyond this many are deleted."
      },
      %{
        key: "backup_uploads",
        section: "Backups",
        type: :boolean,
        label: "Include uploads",
        default: true,
        help:
          "Backups include the uploaded files when they're stored on this server (files in S3 are already kept there)."
      },
      %{
        key: "version_check",
        section: "Updates",
        type: :boolean,
        label: "Check for new versions",
        default: true,
        help:
          "Once a day, asks GitHub for Firefly's latest release, to show on the dashboard when there's a newer one."
      },
      %{
        key: "version_check_notify",
        section: "Updates",
        type: :boolean,
        label: "Notify admins of new versions",
        default: true,
        help: "Admins get a notification when a new version is out (once per version)."
      },
      %{
        key: "embed_username",
        section: "Embedding",
        type: :text,
        label: "Post embedded topics as (username)",
        default: "",
        help:
          "The member who posts the topics made for embedded pages (blog comments). Blank: the first admin."
      },
      %{
        key: "embed_feed_url",
        section: "Embedding",
        type: :text,
        label: "Feed to make topics from (RSS or Atom URL)",
        default: "",
        help:
          "Checked hourly: each new entry on an embeddable host gets its topic. Blank: off (topics are made when a page is first viewed)."
      },
      %{
        key: "chat_enabled",
        section: "Chat",
        type: :boolean,
        label: "Chat",
        default: true,
        help: "Members chat in channels and direct messages at /chat."
      },
      %{
        key: "chat_allowed_groups",
        section: "Chat",
        type: :text,
        label: "Groups that can chat",
        default: "trust_level_0",
        help:
          "Group names, separated by commas (trust_level_0 is every member). Admins always can. Blank: admins only."
      },
      %{
        key: "direct_message_enabled_groups",
        section: "Chat",
        type: :text,
        label: "Groups that can start direct messages",
        default: "trust_level_1",
        help:
          "Group names, separated by commas. Anyone in a direct message can reply to it. Blank: admins only."
      },
      %{
        key: "chat_max_direct_message_users",
        section: "Chat",
        type: :integer,
        label: "People in a direct message",
        default: 20,
        min: 2,
        max: 100,
        help: "The most people a direct message can have, its starter included."
      },
      %{
        key: "chat_channel_wide_mentions_min_trust",
        section: "Chat",
        type: :integer,
        label: "Trust level to mention @here and @all",
        default: 1,
        min: 0,
        max: 4,
        help:
          "@all notifies everyone following the channel, @here those active in the last 5 minutes (where the channel allows them). Admins always can."
      },
      %{
        key: "chat_channel_retention_days",
        section: "Chat",
        type: :integer,
        label: "Delete channel messages after (days)",
        default: 0,
        min: 0,
        max: 3650,
        help: "Messages in channels older than this are deleted, once an hour. 0: kept forever."
      },
      %{
        key: "chat_dm_retention_days",
        section: "Chat",
        type: :integer,
        label: "Delete direct messages after (days)",
        default: 0,
        min: 0,
        max: 3650,
        help:
          "Messages in direct messages older than this are deleted, once an hour. 0: kept forever."
      },
      %{
        key: "ai_enabled",
        section: "AI",
        type: :boolean,
        label: "AI features",
        default: false,
        help:
          "Turns on the AI features set up at /staff/ai (each also needs a provider and to be switched on there). Off: no content is sent to any AI provider."
      },
      %{
        key: "ai_daily_quota_tl0",
        section: "AI",
        type: :integer,
        label: "AI requests a day at trust level 0",
        default: 2,
        min: 0,
        max: 10_000,
        help:
          "How many AI requests (summaries, translations, composer helpers) a member at trust level 0 may make a day. 0: none. Admins have no limit."
      },
      %{
        key: "ai_daily_quota_tl1",
        section: "AI",
        type: :integer,
        label: "AI requests a day at trust level 1",
        default: 10,
        min: 0,
        max: 10_000,
        help:
          "How many AI requests (summaries, translations, composer helpers) a member at trust level 1 may make a day. 0: none. Admins have no limit."
      },
      %{
        key: "ai_daily_quota_tl2",
        section: "AI",
        type: :integer,
        label: "AI requests a day at trust level 2",
        default: 25,
        min: 0,
        max: 10_000,
        help:
          "How many AI requests (summaries, translations, composer helpers) a member at trust level 2 may make a day. 0: none. Admins have no limit."
      },
      %{
        key: "ai_daily_quota_tl3",
        section: "AI",
        type: :integer,
        label: "AI requests a day at trust level 3",
        default: 50,
        min: 0,
        max: 10_000,
        help:
          "How many AI requests (summaries, translations, composer helpers) a member at trust level 3 may make a day. 0: none. Admins have no limit."
      },
      %{
        key: "ai_daily_quota_tl4",
        section: "AI",
        type: :integer,
        label: "AI requests a day at trust level 4",
        default: 100,
        min: 0,
        max: 10_000,
        help:
          "How many AI requests (summaries, translations, composer helpers) a member at trust level 4 may make a day. 0: none. Admins have no limit."
      },
      %{
        key: "ai_prompt_summarize_topic",
        section: "AI prompts",
        type: :text,
        max_length: 4_000,
        label: "Topic summary prompt",
        default: "",
        help: "Replaces the built-in prompt (shown at /staff/ai). Blank: the built-in one."
      },
      %{
        key: "ai_prompt_summarize_chat",
        section: "AI prompts",
        type: :text,
        max_length: 4_000,
        label: "Chat summary prompt",
        default: "",
        help: "Replaces the built-in prompt (shown at /staff/ai). Blank: the built-in one."
      },
      %{
        key: "ai_prompt_translate",
        section: "AI prompts",
        type: :text,
        max_length: 4_000,
        label: "Translation prompt",
        default: "",
        help: "Replaces the built-in prompt (shown at /staff/ai). Blank: the built-in one."
      },
      %{
        key: "ai_prompt_triage",
        section: "AI prompts",
        type: :text,
        max_length: 4_000,
        label: "Triage prompt",
        default: "",
        help: "Replaces the built-in prompt (shown at /staff/ai). Blank: the built-in one."
      },
      %{
        key: "ai_prompt_proofread",
        section: "AI prompts",
        type: :text,
        max_length: 4_000,
        label: "Proofreading prompt",
        default: "",
        help: "Replaces the built-in prompt (shown at /staff/ai). Blank: the built-in one."
      },
      %{
        key: "ai_prompt_suggest_title",
        section: "AI prompts",
        type: :text,
        max_length: 4_000,
        label: "Title suggestion prompt",
        default: "",
        help: "Replaces the built-in prompt (shown at /staff/ai). Blank: the built-in one."
      },
      %{
        key: "ai_prompt_suggest_tags",
        section: "AI prompts",
        type: :text,
        max_length: 4_000,
        label: "Tag suggestion prompt",
        default: "",
        help: "Replaces the built-in prompt (shown at /staff/ai). Blank: the built-in one."
      }
    ]
  end

  @doc "The setting's current value."
  def get(key), do: Map.fetch!(all(), key)

  @doc "Every setting's current value, by key."
  def all, do: elem(cached(), 0)

  @doc """
  Whether an admin has set `key` (a row exists), as opposed to it holding
  its default.
  """
  def customized?(key), do: key in elem(cached(), 1)

  # `{values, customized keys}`. The cache entry is tagged with the
  # generation it was loaded in; invalidating starts a new generation, so an
  # entry a slow reader loaded before a save and put after it is never
  # served.
  defp cached do
    if Application.get_env(:firefly, :site_settings_cache, true) do
      generation = :persistent_term.get(@generation_key, nil)

      case :persistent_term.get(@cache_key, nil) do
        {^generation, values, customized} ->
          {values, customized}

        _missing_or_stale ->
          {values, customized} = load()
          :persistent_term.put(@cache_key, {generation, values, customized})
          {values, customized}
      end
    else
      load()
    end
  end

  defp load do
    stored = Map.new(Repo.all(from(s in SiteSetting, select: {s.key, s.value})))

    values =
      Map.new(definitions(), fn definition ->
        value =
          with raw when is_binary(raw) <- stored[definition.key],
               {:ok, value} <- cast(definition, raw) do
            value
          else
            _unset_or_invalid -> definition.default
          end

        {definition.key, value}
      end)

    {values, MapSet.new(Map.keys(stored))}
  end

  @doc """
  Saves the settings in `params` (key to form value) as `admin`. Each value
  is validated for its type; on any error nothing is saved and the errors
  come back by key. Each changed setting goes to the staff log with its old
  and new values.
  """
  def update(params, admin) do
    current = all()

    {changes, errors} =
      definitions()
      |> Enum.filter(&Map.has_key?(params, &1.key))
      |> Enum.reduce({%{}, %{}}, &collect(&1, params[&1.key], current, &2))

    if errors == %{}, do: save(changes, current, admin), else: {:error, errors}
  end

  # Adds the setting to the changes (if its value changed) or the errors.
  defp collect(%{key: key} = definition, raw, current, {changes, errors}) do
    case cast(definition, raw) do
      {:ok, value} when value == :erlang.map_get(key, current) -> {changes, errors}
      {:ok, value} -> {Map.put(changes, key, value), errors}
      {:error, message} -> {changes, Map.put(errors, key, message)}
    end
  end

  defp save(changes, current, admin) do
    {:ok, _} =
      Repo.transact(fn ->
        for {key, value} <- changes do
          Repo.insert!(%SiteSetting{key: key, value: encode(value)},
            on_conflict: [set: [value: encode(value), updated_at: NaiveDateTime.utc_now()]],
            conflict_target: :key
          )

          StaffLog.record(admin, "setting.update", {"setting", nil}, %{
            key: key,
            value: %{before: current[key], after: value}
          })
        end

        {:ok, changes}
      end)

    if changes != %{}, do: invalidate()
    {:ok, changes}
  end

  defp invalidate do
    clear_cache()
    Phoenix.PubSub.broadcast_from(@pubsub, self(), @topic, :site_settings_changed)
  end

  @doc """
  Reloads every node's settings from the database (after it was replaced
  under them, as by a restore).
  """
  def reload, do: invalidate()

  @doc false
  def topic, do: @topic

  @doc false
  def clear_cache, do: :persistent_term.put(@generation_key, make_ref())

  defp encode(value), do: to_string(value)

  @doc "Casts a form value for the setting's type: `{:ok, value}` or `{:error, message}`."
  def cast(%{type: :boolean}, value) when value in ["true", true], do: {:ok, true}
  def cast(%{type: :boolean}, value) when value in ["false", false], do: {:ok, false}
  def cast(%{type: :boolean}, _value), do: {:error, "must be on or off"}

  def cast(%{type: :integer} = definition, value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n < definition.min -> {:error, "must be at least #{definition.min}"}
      {n, ""} when n > definition.max -> {:error, "must be at most #{definition.max}"}
      {n, ""} -> {:ok, n}
      _ -> {:error, "must be a whole number"}
    end
  end

  def cast(%{type: :string}, value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, "can't be blank"}
      value when byte_size(value) > 100 -> {:error, "must be at most 100 characters"}
      value -> {:ok, value}
    end
  end

  def cast(%{type: :text} = definition, value) when is_binary(value) do
    value = String.trim(value)
    max = definition[:max_length] || 500

    if String.length(value) > max,
      do: {:error, "must be at most #{max} characters"},
      else: {:ok, value}
  end

  def cast(%{type: :email}, value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, ""}

      value ->
        if value =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/,
          do: {:ok, value},
          else: {:error, "must be a valid email"}
    end
  end

  def cast(%{type: :select, options: options}, value) when is_binary(value) do
    if Enum.any?(options, fn {_label, option} -> option == value end),
      do: {:ok, value},
      else: {:error, "is invalid"}
  end

  def cast(_definition, _value), do: {:error, "is invalid"}
end
