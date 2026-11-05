defmodule Firefly.SiteSettings do
  @moduledoc """
  Site settings admins edit at runtime (at `/staff/settings`), stored in
  `forums_site_settings` as key/value rows.

  The settings, their types and defaults are defined here; a row exists only
  for a setting an admin changed, so every default is the behavior the site
  had before settings existed (the rate limits' defaults come from the
  deployment's `Firefly.RateLimit` config). Each setting belongs to a
  `category` (the settings page's tabs) and a `subcategory` (its `section`).

  The deployment can pin any setting with an environment variable,
  `FIREFLY_SETTING_<KEY>` (`FIREFLY_SETTING_TITLE`; `tags_admin_only` keeps
  its older `FIREFLY_TAGS_ADMIN_ONLY`): its value wins over the stored one,
  and the settings page shows it read-only with the variable's name.

  Settings can be reset to their default, each one's history is read from
  the staff log (`history/1`), and they're exported and imported as JSON
  or YAML (see `Firefly.SiteSettings.Transfer`). Secrets are never shown,
  logged or exported.

  Reads are served from `:persistent_term`. An update clears the cache on
  this node at once, and on every node through PubSub (see
  `Firefly.SiteSettings.Cache`), so the next read loads the new values
  (clearing starts a new cache generation, so a read racing the update
  can't put old values back).
  The cache is off in tests (`config :firefly, :site_settings_cache`),
  where each test's settings live in its own database transaction.
  """

  use Boundary, top_level?: true, check: [out: false], exports: [Transfer, SiteSetting]

  import Ecto.Query

  alias Firefly.{RateLimit, Repo}
  alias Firefly.Moderation.StaffLog
  alias Firefly.SiteSettings.SiteSetting

  @pubsub Firefly.PubSub
  @topic "site_settings"
  @cache_key {__MODULE__, :values}
  @generation_key {__MODULE__, :generation}

  # The settings page's tabs, and the sections (subcategories) in each.
  @categories [
    {"Basic", ["Site", "Appearance"]},
    {"Users", ["Registration", "Logins", "New members", "Directory", "SAML", "Trust levels"]},
    {"Posting",
     ["Content", "Spam and new users", "Akismet", "Uploads", "Link previews", "Search"]},
    {"Email", ["Email"]},
    {"Security", ["Rate limits", "API"]},
    {"Chat", ["Chat"]},
    {"AI", ["AI", "AI prompts"]},
    {"Search engines", ["Search engines", "Analytics"]},
    {"Advanced", ["Plugins", "Backups", "Jobs", "Updates", "Embedding", "Database"]}
  ]

  @doc "The categories, in order: `{name, sections}`."
  def categories, do: @categories

  @doc """
  Every setting, in display order (by category and section): `key`,
  `category`, `subcategory` (and
  `section`, the same), `type` (`:string`, `:text`, `:email`,
  `:boolean`, `:integer`, `:select`, `:list`, `:color` or `:upload`),
  `label`, `help`, `default`, `env` (the environment variable that pins
  it), for integers `min`/`max`, for texts optionally `max_length` (500
  characters by default) and `secret` (never shown, logged or exported),
  for selects `options` (`{label, value}` pairs), and for lists
  optionally `options` (the values allowed).
  """
  def definitions do
    sections = Enum.flat_map(@categories, &elem(&1, 1))

    (core_definitions() ++ extra_definitions())
    |> Enum.map(&finish/1)
    |> Enum.sort_by(&Enum.find_index(sections, fn section -> section == &1.section end))
  end

  defp finish(%{section: section, key: key} = definition) do
    {category, _sections} =
      Enum.find(@categories, fn {_name, sections} -> section in sections end)

    definition
    |> Map.put(:category, category)
    |> Map.put(:subcategory, section)
    |> Map.put_new(:env, "FIREFLY_SETTING_" <> String.upcase(key))
  end

  defp core_definitions do
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
        key: "default_locale",
        section: "Site",
        type: :select,
        label: "Language",
        default: "en",
        options: [
          {"English", "en"},
          {"Español", "es"},
          {"Français", "fr"},
          {"Deutsch", "de"},
          {"Português (Brasil)", "pt_BR"},
          {"日本語", "ja"},
          {"简体中文", "zh_CN"},
          {"العربية", "ar"}
        ],
        help:
          "The interface's language for visitors whose browser asks for none Firefly has. Members pick their own in their settings."
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
        key: "must_approve_users",
        section: "Registration",
        type: :boolean,
        label: "Staff approve new accounts",
        default: false,
        help:
          "On: new accounts can read but not post until a staff member approves them (Users, Pending). Invited people are approved by their invitation."
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
        key: "ldap_replaces_password",
        section: "Logins",
        type: :boolean,
        label: "LDAP replaces local passwords",
        default: false,
        help:
          "With an LDAP directory configured (FIREFLY_LDAP_*): members log in with their directory password, and local passwords, registration, email login links and passkeys are off."
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
        key: "discourse_connect_provider_enabled",
        section: "Logins",
        type: :boolean,
        label: "Be a DiscourseConnect provider",
        default: false,
        help:
          "Other sites log people in with their accounts here, through DiscourseConnect (add each site at Staff, DiscourseConnect)."
      },
      %{
        key: "discourse_connect_provider_require_two_factor",
        section: "Logins",
        type: :boolean,
        label: "Two-factor for DiscourseConnect provider logins",
        default: false,
        help:
          "Members must turn on two-factor authentication before logging in to other sites through this one."
      },
      %{
        key: "saml_enabled",
        section: "SAML",
        type: :boolean,
        label: "SAML login",
        default: false,
        help:
          "Log in with a SAML 2.0 identity provider (configured below). Give it this site's metadata, at /saml/metadata."
      },
      %{
        key: "saml_name",
        section: "SAML",
        type: :string,
        label: "Login button name",
        default: "SAML",
        help: "What the login button says: \"Log in with ...\"."
      },
      %{
        key: "saml_idp_metadata_url",
        section: "SAML",
        type: :text,
        label: "Identity provider metadata URL",
        default: "",
        help:
          "Where the identity provider publishes its metadata (fetched hourly). Or paste the metadata below, or fill in its entity id, login URL and certificate."
      },
      %{
        key: "saml_idp_metadata_xml",
        section: "SAML",
        type: :text,
        max_length: 100_000,
        label: "Identity provider metadata",
        default: "",
        help: "The identity provider's metadata XML, if it isn't published at a URL."
      },
      %{
        key: "saml_idp_entity_id",
        section: "SAML",
        type: :text,
        label: "Identity provider entity id",
        default: "",
        help: "Its issuer name. Blank: the metadata's."
      },
      %{
        key: "saml_idp_sso_url",
        section: "SAML",
        type: :text,
        label: "Identity provider login URL",
        default: "",
        help: "Its single sign-on service (HTTP-Redirect binding). Blank: the metadata's."
      },
      %{
        key: "saml_idp_certificate",
        section: "SAML",
        type: :text,
        max_length: 20_000,
        label: "Identity provider certificate",
        default: "",
        help:
          "Its signing certificate (PEM), trusted along with the metadata's (for a key rollover)."
      },
      %{
        key: "saml_sp_entity_id",
        section: "SAML",
        type: :text,
        label: "This site's entity id",
        default: "",
        help: "Blank: the metadata URL (/saml/metadata). Assertions must be for this audience."
      },
      %{
        key: "saml_uid_attribute",
        section: "SAML",
        type: :text,
        label: "Account id attribute",
        default: "",
        help:
          "The attribute that identifies the account for good. Blank: the NameID (ask for a persistent one)."
      },
      %{
        key: "saml_email_attributes",
        section: "SAML",
        type: :text,
        label: "Email attributes",
        default:
          "email, mail, urn:oid:0.9.2342.19200300.100.1.3, http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress",
        help: "Attribute names (or friendly names) for the email address, the first present wins."
      },
      %{
        key: "saml_username_attributes",
        section: "SAML",
        type: :text,
        label: "Username attributes",
        default: "username, uid, urn:oid:0.9.2342.19200300.100.1.1",
        help: "For a new account's username (made unique)."
      },
      %{
        key: "saml_name_attributes",
        section: "SAML",
        type: :text,
        label: "Name attributes",
        default:
          "name, displayName, cn, urn:oid:2.16.840.1.113730.3.1.241, http://schemas.microsoft.com/identity/claims/displayname",
        help: "For the member's full name."
      },
      %{
        key: "saml_groups_attributes",
        section: "SAML",
        type: :text,
        label: "Groups attributes",
        default: "",
        help:
          "When set, each login makes the member's groups those listed there (only groups that exist here; admin and moderator aren't touched). Blank: groups aren't synced."
      },
      %{
        key: "saml_trust_email",
        section: "SAML",
        type: :boolean,
        label: "Trust SAML email addresses",
        default: true,
        help: "New accounts' addresses count as confirmed (the identity provider verified them)."
      },
      %{
        key: "saml_sign_requests",
        section: "SAML",
        type: :boolean,
        label: "Sign login requests",
        default: false,
        help:
          "Sign AuthnRequests with the key and certificate in FIREFLY_SAML_SP_KEY and FIREFLY_SAML_SP_CERT."
      },
      %{
        key: "saml_idp_initiated",
        section: "SAML",
        type: :boolean,
        label: "Allow logins started at the identity provider",
        default: false,
        help:
          "Accept responses that answer no request of ours (from the identity provider's app list). Such logins can't be tied to the browser, so they're off unless needed."
      },
      %{
        key: "akismet_enabled",
        section: "Akismet",
        type: :boolean,
        label: "Check new content with Akismet",
        default: false,
        help:
          "Akismet (akismet.com) checks what members below the trust level below post, in the background; spam is hidden and queued for review."
      },
      %{
        key: "akismet_api_key",
        section: "Akismet",
        type: :text,
        secret: true,
        label: "Akismet API key",
        default: "",
        help: "From your akismet.com account. The staff log records only that it changed."
      },
      %{
        key: "akismet_trust_level",
        section: "Akismet",
        type: :integer,
        min: 1,
        max: 5,
        label: "Check members below trust level",
        default: 2,
        help:
          "Members at this trust level or above (and admins) aren't checked. 5: everyone else is."
      },
      %{
        key: "akismet_check_posts",
        section: "Akismet",
        type: :boolean,
        label: "Check posts",
        default: true,
        help: "New topics and replies."
      },
      %{
        key: "akismet_check_messages",
        section: "Akismet",
        type: :boolean,
        label: "Check private messages",
        default: true,
        help: "New private messages."
      },
      %{
        key: "akismet_check_chat",
        section: "Akismet",
        type: :boolean,
        label: "Check chat messages",
        default: true,
        help: "New chat messages."
      },
      %{
        key: "akismet_check_profiles",
        section: "Akismet",
        type: :boolean,
        label: "Check profiles",
        default: true,
        help: "Bios, websites and locations, as members change them."
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
        default: false,
        env: "FIREFLY_TAGS_ADMIN_ONLY",
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
        key: "email_log_days",
        section: "Email",
        type: :integer,
        label: "Keep the email log (days)",
        default: 30,
        min: 1,
        max: 365,
        help: "How long the log of sent emails (Staff, Emails) keeps each entry."
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
        key: "allow_indexing",
        section: "Search engines",
        type: :boolean,
        label: "Allow indexing",
        default: true,
        help:
          "Off: robots.txt asks every crawler to stay away, pages say noindex and the sitemap is empty. Public content only is ever listed."
      },
      %{
        key: "index_user_pages",
        section: "Search engines",
        type: :boolean,
        label: "Index member pages",
        default: false,
        help:
          "Whether profiles, the members directory, groups and badges may be indexed. Off: they say noindex and stay out of the sitemap."
      },
      %{
        key: "robots_extra",
        section: "Search engines",
        type: :text,
        label: "Extra robots.txt rules",
        default: "",
        max_length: 2000,
        help:
          "Added to robots.txt after the built-in rules, e.g. a Crawl-delay or rules for one crawler."
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
        key: "job_retention_days",
        section: "Jobs",
        type: :integer,
        label: "Keep finished jobs (days)",
        default: 14,
        min: 1,
        max: 365,
        help:
          "How long completed, cancelled and failed background jobs stay in the job history (Staff, Jobs) before they're pruned."
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
        key: "enable_database_admin",
        section: "Database",
        type: :boolean,
        label: "Raw database admin",
        default: false,
        help:
          "Lets admins browse and edit records directly at /staff/db, for what the admin pages don't cover. Its edits skip the forum's own checks. Off: the page doesn't exist."
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
        type: :list,
        label: "Groups that can chat",
        default: ["trust_level_0"],
        help:
          "Group names, separated by commas (trust_level_0 is every member). Admins always can. Blank: admins only."
      },
      %{
        key: "direct_message_enabled_groups",
        section: "Chat",
        type: :list,
        label: "Groups that can start direct messages",
        default: ["trust_level_1"],
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
        key: "api_rate_limit",
        section: "API",
        type: :integer,
        label: "API requests per minute",
        default: 120,
        min: 1,
        max: 100_000,
        help:
          "How many requests an API key may make a minute, unless the key sets its own limit (see /api/v1/docs)."
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
        key: "ai_related_topics",
        section: "AI",
        type: :boolean,
        label: "Related topics",
        default: true,
        help:
          "With semantic search on, topics end with the topics nearest them in meaning (those the reader may read)."
      },
      %{
        key: "mcp_enabled",
        section: "AI",
        type: :boolean,
        label: "MCP server",
        default: false,
        help:
          "AI assistants and agents can read the forum through the Model Context Protocol at /mcp (search, read topics, list the latest, look up members), authenticated with an API key with the read scope and seeing only what that member may read."
      },
      %{
        key: "ai_summary_min_posts",
        section: "AI",
        type: :integer,
        label: "Summaries for topics with at least (posts)",
        default: 10,
        min: 2,
        max: 1_000,
        help: "Topics this long get a Summarize button (with the Summaries feature on)."
      },
      %{
        key: "ai_summary_stale_posts",
        section: "AI",
        type: :integer,
        label: "Summarize again after (new posts)",
        default: 5,
        min: 1,
        max: 1_000,
        help: "A topic's summary is kept until this many posts were added since it was made."
      },
      %{
        key: "ai_triage_flag_threshold",
        section: "AI",
        type: :integer,
        label: "Triage flags posts rated at least",
        default: 70,
        min: 0,
        max: 100,
        help:
          "Posts triage rates this toxic or spammy (0 to 100) are flagged into the review queue. 0: never."
      },
      %{
        key: "ai_triage_hide_threshold",
        section: "AI",
        type: :integer,
        label: "Triage hides posts rated at least",
        default: 0,
        min: 0,
        max: 100,
        help:
          "Posts triage rates this toxic or spammy are flagged and hidden until staff review them (admins' posts are only flagged). 0: never."
      },
      %{
        key: "ai_triage_tag",
        section: "AI",
        type: :text,
        label: "Tag topics triage flags",
        default: "",
        help: "A tag added to the topic of a post triage flags or hides. Blank: none."
      },
      %{
        key: "ai_composer_proofread",
        section: "AI",
        type: :boolean,
        label: "Composer: proofread",
        default: true,
        help: "Offers to fix spelling and grammar in the composer (with Composer helpers on)."
      },
      %{
        key: "ai_composer_title",
        section: "AI",
        type: :boolean,
        label: "Composer: suggest a title",
        default: true,
        help: "Offers a title for a new topic from its first post."
      },
      %{
        key: "ai_composer_tags",
        section: "AI",
        type: :boolean,
        label: "Composer: suggest tags",
        default: true,
        help: "Offers tags for a new topic from its first post."
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

  # Tunables that were constants or deployment config before.
  defp extra_definitions do
    appearance_definitions() ++
      account_definitions() ++
      member_default_definitions() ++
      limit_definitions() ++ rate_limit_definitions()
  end

  defp appearance_definitions do
    [
      %{
        key: "theme_color",
        section: "Appearance",
        type: :color,
        label: "Browser theme color",
        default: "#db3440",
        help: "The color mobile browsers tint their toolbar with (the theme-color meta tag)."
      },
      %{
        key: "default_theme_id",
        section: "Appearance",
        type: :integer,
        label: "Default theme",
        default: 0,
        min: 0,
        max: 2_147_483_647,
        help:
          "The id of the theme every page uses (set it with Make default at Staff, Themes). 0: the built-in look."
      },
      %{
        key: "logo_url",
        section: "Appearance",
        type: :upload,
        label: "Logo",
        default: "",
        help:
          "An image shown in the header instead of the Firefly icon (next to the title). Blank: the Firefly icon."
      }
    ]
  end

  defp account_definitions do
    [
      %{
        key: "min_username_length",
        section: "Registration",
        type: :integer,
        label: "Shortest username",
        default: 2,
        min: 1,
        max: 20,
        help: "How many characters a new username must have at least."
      },
      %{
        key: "max_username_length",
        section: "Registration",
        type: :integer,
        label: "Longest username",
        default: 32,
        min: 10,
        max: 60,
        help: "How many characters a new username may have at most."
      },
      %{
        key: "min_password_length",
        section: "Registration",
        type: :integer,
        label: "Shortest password",
        default: 8,
        min: 8,
        max: 72,
        help:
          "How many characters a new password must have at least (72 is the most passwords can have)."
      },
      %{
        key: "reserved_usernames",
        section: "Registration",
        type: :list,
        label: "Reserved usernames",
        default: [],
        help:
          "Usernames nobody can sign up with (any case), separated by commas, e.g. support, staff."
      },
      %{
        key: "email_confirmation_days",
        section: "Logins",
        type: :integer,
        label: "Confirmation links last (days)",
        default: 7,
        min: 1,
        max: 30,
        help: "How long the link that confirms an email address works."
      },
      %{
        key: "password_reset_hours",
        section: "Logins",
        type: :integer,
        label: "Password reset links last (hours)",
        default: 1,
        min: 1,
        max: 72,
        help: "How long a password reset link works (once)."
      },
      %{
        key: "magic_link_minutes",
        section: "Logins",
        type: :integer,
        label: "Email login links last (minutes)",
        default: 15,
        min: 5,
        max: 1440,
        help: "How long an emailed login link works (once)."
      },
      %{
        key: "directory_page_size",
        section: "Directory",
        type: :integer,
        label: "Members per page",
        default: 20,
        min: 5,
        max: 100,
        help: "How many members the users directory lists a page."
      }
    ]
  end

  defp member_default_definitions do
    [
      default(
        "default_email_notifications",
        :boolean,
        "Email notifications",
        true,
        "Whether new members get notification emails until they change it."
      ),
      default(
        "default_allow_private_messages",
        :boolean,
        "Accept private messages",
        true,
        "Whether new members can be sent private messages until they change it."
      ),
      default(
        "default_keyboard_shortcuts",
        :boolean,
        "Keyboard shortcuts",
        true,
        "Whether keyboard shortcuts are on for new members."
      ),
      default(
        "default_push_only_when_away",
        :boolean,
        "Browser notifications only when away",
        true,
        "Whether new members' browser notifications wait until they're away from the site."
      ),
      Map.put(
        default(
          "default_reply_level",
          :select,
          "Level for threads they reply to",
          "tracking",
          "The notification level new members' replies set on a thread."
        ),
        :options,
        [{"Tracking", "tracking"}, {"Normal", "normal"}]
      ),
      Map.put(
        default(
          "default_new_thread_level",
          :select,
          "Level for threads they start",
          "watching",
          "The notification level new members' own threads start at."
        ),
        :options,
        [{"Watching", "watching"}, {"Tracking", "tracking"}]
      )
    ]
  end

  defp default(key, type, label, default, help),
    do: %{
      key: key,
      section: "New members",
      type: type,
      label: label,
      default: default,
      help: help
    }

  defp limit_definitions do
    [
      %{
        key: "max_post_length",
        section: "Content",
        type: :integer,
        label: "Longest post (characters)",
        default: 32_000,
        min: 500,
        max: 100_000,
        help: "How long a thread's first post, a reply or a private message may be."
      },
      %{
        key: "max_chat_message_length",
        section: "Chat",
        type: :integer,
        label: "Longest chat message (characters)",
        default: 6000,
        min: 100,
        max: 20_000,
        help: "How long one chat message may be."
      },
      %{
        key: "search_results_per_page",
        section: "Search",
        type: :integer,
        label: "Results per page",
        default: 20,
        min: 5,
        max: 100,
        help: "How many results a search page shows (keyword and semantic search)."
      },
      %{
        key: "authorized_extensions",
        section: "Uploads",
        type: :list,
        label: "Allowed file types",
        default: ~w(png jpg gif webp svg pdf txt),
        options: ~w(png jpg gif webp svg pdf txt),
        help:
          "Which kinds of file members may attach (by extension; the content must match). Firefly accepts at most these: png, jpg, gif, webp, svg (made a PNG image), pdf, txt."
      },
      %{
        key: "email_from_name",
        section: "Email",
        type: :string,
        label: "Sender name",
        default: elem(Application.get_env(:firefly, :email, [])[:from] || {"Firefly", nil}, 0),
        help: "The name emails come from (the address is the deployment's)."
      },
      %{
        key: "digest_max_notifications",
        section: "Email",
        type: :integer,
        label: "Notifications in a digest",
        default: 5,
        min: 0,
        max: 50,
        help: "How many unread notifications a digest email lists."
      }
    ]
  end

  # Each limit's count; its window stays the deployment's (see Firefly.RateLimit).
  @rate_limits [
    {"login", "Login attempts per username", "per 5 minutes"},
    {"login_ip", "Login attempts per IP address", "per 5 minutes"},
    {"register", "Sign-ups per IP address", "per hour"},
    {"upload", "Uploads per member", "per hour"},
    {"like", "Likes per member", "per 5 minutes"},
    {"message", "New private conversations per member", "per hour"},
    {"chat", "Chat messages per member", "per minute"},
    {"export", "Account exports per member", "per hour"},
    {"email", "Account emails per member", "per hour"},
    {"two_factor", "Second-factor attempts per member", "per 5 minutes"},
    {"magic_link", "Email login link requests", "per hour"},
    {"password_reset", "Password reset requests per IP address", "per hour"},
    {"search", "Searches per member or visitor", "per minute"},
    {"ai", "AI requests per member", "per minute"},
    {"mcp", "MCP requests per member", "per minute"},
    {"flag", "Flags per member", "per hour"},
    {"invite", "Invitations per member", "per hour"},
    {"plugin_notify", "Notifications per plugin", "per hour"},
    {"plugin_call", "Plugin widget calls per member", "per minute"},
    {"plugin_api", "Plugin endpoint requests per IP address", "per minute"},
    {"plugin_storage", "Plugin storage writes per member", "per minute"}
  ]

  defp rate_limit_definitions do
    for {bucket, label, window} <- @rate_limits do
      %{
        key: "rate_limit_" <> bucket,
        section: "Rate limits",
        type: :integer,
        label: label,
        default: RateLimit.configured_limit(String.to_existing_atom(bucket)),
        min: 1,
        max: 100_000,
        help: "How many are allowed #{window} (the window is the deployment's)."
      }
    end
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
          with raw when is_binary(raw) <- env_value(definition) || stored[definition.key],
               {:ok, value} <- cast(definition, raw) do
            value
          else
            _unset_or_invalid -> definition.default
          end

        {definition.key, value}
      end)

    {values, MapSet.new(Map.keys(stored))}
  end

  defp env_value(%{env: env}) do
    case System.get_env(env) do
      nil -> nil
      value -> value
    end
  end

  @doc """
  The environment variable pinning `key`'s value, when it's set (the
  setting can't be changed here then), else nil.
  """
  def env_override(key) do
    case Enum.find(definitions(), &(&1.key == key)) do
      %{env: env} -> if System.get_env(env), do: env
      nil -> nil
    end
  end

  @doc "The definition of `key`, or nil."
  def definition(key), do: Enum.find(definitions(), &(&1.key == key))

  @doc """
  Resets `key` to its default as `admin`: its stored value goes, and the
  staff log records the change (`reset: true`). A setting already at its
  default is left as it is (`{:ok, :unchanged}`).
  """
  def reset(key, admin) do
    definition = definition(key)

    cond do
      is_nil(definition) ->
        {:error, :unknown}

      not customized?(key) ->
        {:ok, :unchanged}

      true ->
        before = get(key)

        {:ok, _} =
          Repo.transact(fn ->
            Repo.delete_all(from(s in SiteSetting, where: s.key == ^key))

            StaffLog.record(admin, "setting.update", {"setting", nil}, %{
              key: key,
              reset: true,
              value: logged_value(key, before, definition.default)
            })

            {:ok, key}
          end)

        invalidate()
        {:ok, :reset}
    end
  end

  @doc """
  The staff log's changes to `key`, newest first: maps with `at`, `actor`
  (a user or nil), `before`, `after` and `reset`.
  """
  def history(key, limit \\ 20) do
    for entry <- StaffLog.setting_history(key, limit) do
      value = entry.details["value"] || %{}

      %{
        at: entry.inserted_at,
        actor: entry.actor,
        before: value["before"],
        after: value["after"],
        reset: entry.details["reset"] == true
      }
    end
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
    case {cast(definition, raw), System.get_env(definition.env)} do
      {{:ok, value}, _pinned} when value == :erlang.map_get(key, current) ->
        {changes, errors}

      {_changed_or_invalid, pinned} when is_binary(pinned) ->
        {changes, Map.put(errors, key, "is set by #{definition.env}")}

      {{:ok, value}, nil} ->
        {Map.put(changes, key, value), errors}

      {{:error, message}, nil} ->
        {changes, Map.put(errors, key, message)}
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
            value: logged_value(key, current[key], value)
          })
        end

        {:ok, changes}
      end)

    if changes != %{}, do: invalidate()
    {:ok, changes}
  end

  # Secrets (an API key) aren't written to the log, only that they changed.
  defp logged_value(key, before, value) do
    if Enum.any?(definitions(), &(&1.key == key and &1[:secret])),
      do: %{before: "[secret]", after: "[secret]"},
      else: %{before: before, after: value}
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

  defp encode(value) when is_list(value), do: Enum.join(value, ",")
  defp encode(value), do: to_string(value)

  @doc "Casts a form value for the setting's type: `{:ok, value}` or `{:error, message}`."
  def cast(%{type: :boolean}, value) when value in ["true", "1", true], do: {:ok, true}
  def cast(%{type: :boolean}, value) when value in ["false", "0", false], do: {:ok, false}
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

  def cast(%{type: :list} = definition, value) when is_binary(value),
    do: cast(definition, String.split(value, ~r/[,\n]/))

  def cast(%{type: :list} = definition, values) when is_list(values) do
    values =
      values
      |> Enum.map(&(&1 |> to_string() |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    allowed = definition[:options]

    cond do
      Enum.any?(values, &(String.length(&1) > 100)) ->
        {:error, "has an item longer than 100 characters"}

      allowed && Enum.any?(values, &(&1 not in allowed)) ->
        {:error, "may only hold #{Enum.join(allowed, ", ")}"}

      true ->
        {:ok, values}
    end
  end

  def cast(%{type: :color}, value) when is_binary(value) do
    value = value |> String.trim() |> String.downcase()

    if value =~ ~r/^#[0-9a-f]{6}$/,
      do: {:ok, value},
      else: {:error, "must be a color like #3b82f6"}
  end

  # An upload's path (see Firefly.Uploads), or blank for none.
  def cast(%{type: :upload}, value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        {:ok, ""}

      "/uploads/" <> _ = path ->
        if path =~ ~r{^/uploads/[A-Za-z0-9_-]+/[^/\s]+$},
          do: {:ok, path},
          else: {:error, "is invalid"}

      _other ->
        {:error, "must be an uploaded file"}
    end
  end

  def cast(_definition, _value), do: {:error, "is invalid"}
end
