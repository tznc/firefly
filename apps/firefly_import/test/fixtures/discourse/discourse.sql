-- A small Discourse database: the tables and columns the importer reads,
-- as Discourse has them, with a few records of each.

CREATE TABLE users (
  id integer PRIMARY KEY, username varchar NOT NULL, name varchar,
  created_at timestamp NOT NULL, updated_at timestamp NOT NULL, last_seen_at timestamp,
  active boolean NOT NULL DEFAULT false, trust_level integer NOT NULL DEFAULT 0,
  suspended_till timestamp, silenced_till timestamp, uploaded_avatar_id integer
);
CREATE TABLE user_emails (id serial PRIMARY KEY, user_id integer, email varchar, "primary" boolean);
CREATE TABLE user_profiles (user_id integer PRIMARY KEY, bio_raw text, website varchar, location varchar);
CREATE TABLE single_sign_on_records (id serial PRIMARY KEY, user_id integer, external_id varchar);
CREATE TABLE user_associated_accounts (
  id serial PRIMARY KEY, provider_name varchar, provider_uid varchar, user_id integer
);
CREATE TABLE uploads (
  id integer PRIMARY KEY, user_id integer, original_filename varchar, url varchar, sha1 varchar
);
CREATE TABLE groups (
  id integer PRIMARY KEY, name varchar, full_name varchar, bio_raw text, automatic boolean,
  created_at timestamp
);
CREATE TABLE group_users (id serial PRIMARY KEY, group_id integer, user_id integer, owner boolean);
CREATE TABLE categories (
  id integer PRIMARY KEY, name varchar, slug varchar, description text, color varchar,
  position integer, parent_category_id integer, read_restricted boolean, created_at timestamp
);
CREATE TABLE category_groups (id serial PRIMARY KEY, category_id integer, group_id integer);
CREATE TABLE category_custom_fields (id serial PRIMARY KEY, category_id integer, name varchar, value text);
CREATE TABLE tags (id integer PRIMARY KEY, name varchar);
CREATE TABLE tag_groups (id integer PRIMARY KEY, name varchar);
CREATE TABLE tag_group_memberships (id serial PRIMARY KEY, tag_id integer, tag_group_id integer);
CREATE TABLE topics (
  id integer PRIMARY KEY, title varchar, slug varchar, category_id integer, user_id integer,
  views integer, pinned_at timestamp, closed boolean, archived boolean, archetype varchar,
  created_at timestamp, updated_at timestamp, bumped_at timestamp, deleted_at timestamp
);
CREATE TABLE topic_tags (id serial PRIMARY KEY, topic_id integer, tag_id integer);
CREATE TABLE topic_allowed_users (id serial PRIMARY KEY, topic_id integer, user_id integer);
CREATE TABLE topic_allowed_groups (id serial PRIMARY KEY, topic_id integer, group_id integer);
CREATE TABLE posts (
  id integer PRIMARY KEY, topic_id integer, post_number integer, user_id integer, raw text,
  cooked text, wiki boolean DEFAULT false, version integer DEFAULT 1, last_version_at timestamp,
  post_type integer DEFAULT 1, created_at timestamp, updated_at timestamp, deleted_at timestamp
);
CREATE TABLE post_actions (
  id serial PRIMARY KEY, post_id integer, user_id integer, post_action_type_id integer,
  created_at timestamp, deleted_at timestamp
);
CREATE TABLE bookmarks (
  id serial PRIMARY KEY, user_id integer, bookmarkable_id integer, bookmarkable_type varchar,
  name varchar, created_at timestamp
);
CREATE TABLE polls (
  id integer PRIMARY KEY, post_id integer, name varchar, type integer, status integer,
  results integer, visibility integer, min integer, max integer, close_at timestamp,
  created_at timestamp, updated_at timestamp
);
CREATE TABLE poll_options (id integer PRIMARY KEY, poll_id integer, html text);
CREATE TABLE poll_votes (id serial PRIMARY KEY, poll_id integer, poll_option_id integer, user_id integer);
CREATE TABLE discourse_solved_solved_topics (id serial PRIMARY KEY, topic_id integer, answer_post_id integer);
CREATE TABLE permalinks (
  id serial PRIMARY KEY, url varchar, topic_id integer, post_id integer, category_id integer,
  tag_id integer, external_url varchar
);

-- System users (negative ids) aren't imported.
INSERT INTO users VALUES
  (-1, 'system', 'system', '2020-01-01', '2020-01-01', NULL, true, 4, NULL, NULL, NULL),
  (1, 'alice.smith', 'Alice Smith', '2020-01-02 10:00:00', '2020-01-02 10:00:00', '2024-05-01', true, 3, NULL, NULL, 2),
  (2, 'bob', 'Bob', '2020-02-03 11:00:00', '2020-02-03 11:00:00', '2024-04-01', true, 1, '2999-01-01', NULL, NULL),
  (3, 'carol', NULL, '2021-03-04 12:00:00', '2021-03-04 12:00:00', NULL, false, 0, NULL, NULL, NULL);
INSERT INTO user_emails (user_id, email, "primary") VALUES
  (1, 'alice@example.com', true), (1, 'alice.old@example.com', false), (2, 'bob@example.com', true);
INSERT INTO user_profiles VALUES (1, 'I like **Elixir**.', 'https://alice.example.com', 'Lisbon');
INSERT INTO single_sign_on_records (user_id, external_id) VALUES (1, 'sso-alice');
INSERT INTO user_associated_accounts (provider_name, provider_uid, user_id) VALUES ('github', '4242', 2);

INSERT INTO uploads VALUES
  (1, 1, 'logo.png', '/uploads/default/original/1X/f7fd0f398ffafb0344df6e161a68642e598a3e88.png', 'f7fd0f398ffafb0344df6e161a68642e598a3e88'),
  (2, 1, 'avatar.png', '/uploads/default/original/1X/e54a16c95a8ea72fae446648307470e43928044a.png', 'e54a16c95a8ea72fae446648307470e43928044a');

INSERT INTO groups VALUES
  (10, 'trust_level_1', NULL, NULL, true, '2020-01-01'),
  (11, 'team', 'The team', 'Our **team**.', false, '2020-01-05');
INSERT INTO group_users (group_id, user_id, owner) VALUES (10, 1, false), (11, 1, true), (11, 2, false);

INSERT INTO categories VALUES
  (20, 'General', 'general', '<p>Talk about anything.</p>', '0088CC', 1, NULL, false, '2020-01-01'),
  (21, 'Help', 'help', NULL, 'F7941D', 2, 20, false, '2020-01-01'),
  (22, 'Deep', 'deep', NULL, NULL, 1, 21, false, '2020-01-01'),
  (23, 'Team', 'team', NULL, NULL, 3, NULL, true, '2020-01-01');
INSERT INTO category_groups (category_id, group_id) VALUES (23, 11);
INSERT INTO category_custom_fields (category_id, name, value) VALUES (21, 'enable_accepted_answers', 'true');

INSERT INTO tags VALUES (30, 'elixir'), (31, 'Phoenix Framework');
INSERT INTO tag_groups VALUES (40, 'Languages');
INSERT INTO tag_group_memberships (tag_id, tag_group_id) VALUES (30, 40);

INSERT INTO topics VALUES
  (100, 'Welcome to the forum', 'welcome-to-the-forum', 20, 1, 42, '2020-03-01', false, false, 'regular', '2020-03-01 09:00:00', '2020-03-02', '2020-03-02', NULL),
  (101, 'How do I deploy?', 'how-do-i-deploy', 21, 2, 7, NULL, true, false, 'regular', '2020-04-01 09:00:00', '2020-04-03', '2020-04-03', NULL),
  (102, 'Deleted topic', 'deleted-topic', 20, 2, 0, NULL, false, false, 'regular', '2020-04-01', '2020-04-01', '2020-04-01', '2020-04-02'),
  (103, 'Hi Bob', 'hi-bob', NULL, 1, 0, NULL, false, false, 'private_message', '2020-05-01 08:00:00', '2020-05-01', '2020-05-01', NULL),
  (104, 'Deep thoughts', 'deep-thoughts', 22, 3, 1, NULL, false, false, 'regular', '2021-04-01', '2021-04-01', '2021-04-01', NULL);
INSERT INTO topic_tags (topic_id, tag_id) VALUES (100, 30), (100, 31);
INSERT INTO topic_allowed_users (topic_id, user_id) VALUES (103, 1), (103, 2);

INSERT INTO posts (id, topic_id, post_number, user_id, raw, cooked, wiki, version, last_version_at, post_type, created_at, updated_at, deleted_at) VALUES
  (1000, 100, 1, 1, E'Hello **everyone**!\n\n![logo|4x4](upload://ZNo6yuLTZ7OT59JtNhNmTCluryy.png)\n\n[poll type=regular]\n* Yes\n* No\n[/poll]', '<p>Hello</p>', true, 2, '2020-03-01 10:00:00', 1, '2020-03-01 09:00:00', '2020-03-01 10:00:00', NULL),
  (1001, 100, 2, 2, E'[quote="alice.smith, post:1, topic:100"]\nHello **everyone**!\n[/quote]\n\nHi [b]Alice[/b]!', '', false, 1, NULL, 1, '2020-03-01 12:00:00', '2020-03-01 12:00:00', NULL),
  (1002, 100, 3, 1, '', '', false, 1, NULL, 3, '2020-03-01 13:00:00', '2020-03-01 13:00:00', NULL),
  (1003, 100, 4, 99, '', '<p>From a <strong>deleted</strong> user, see <a href="https://example.com">this</a>.</p>', false, 1, NULL, 1, '2020-03-01 14:00:00', '2020-03-01 14:00:00', NULL),
  (1010, 101, 1, 2, 'It fails.', '', false, 1, NULL, 1, '2020-04-01 09:00:00', '2020-04-01 09:00:00', NULL),
  (1011, 101, 2, 1, 'Use a release.', '', false, 1, NULL, 1, '2020-04-02 09:00:00', '2020-04-02 09:00:00', NULL),
  (1012, 101, 3, 2, 'Spam', '', false, 1, NULL, 1, '2020-04-02 10:00:00', '2020-04-02 10:00:00', '2020-04-02 11:00:00'),
  (1020, 102, 1, 2, 'Gone', '', false, 1, NULL, 1, '2020-04-01', '2020-04-01', NULL),
  (1030, 103, 1, 1, 'Hi Bob, how are you?', '', false, 1, NULL, 1, '2020-05-01 08:00:00', '2020-05-01 08:00:00', NULL),
  (1031, 103, 2, 2, 'Fine, thanks!', '', false, 1, NULL, 1, '2020-05-01 09:00:00', '2020-05-01 09:00:00', NULL),
  (1040, 104, 1, 3, 'Hmm.', '', false, 1, NULL, 1, '2021-04-01', '2021-04-01', NULL);

INSERT INTO post_actions (post_id, user_id, post_action_type_id, created_at, deleted_at) VALUES
  (1000, 2, 2, '2020-03-01 12:00:00', NULL),
  (1001, 1, 2, '2020-03-01 12:30:00', NULL),
  (1010, 1, 2, '2020-04-01 10:00:00', '2020-04-01 11:00:00'),
  (1010, 1, 3, '2020-04-01 10:00:00', NULL),
  (1030, 2, 2, '2020-05-01 09:00:00', NULL);
INSERT INTO bookmarks (user_id, bookmarkable_id, bookmarkable_type, name, created_at) VALUES
  (2, 1011, 'Post', 'the answer', '2020-04-02 12:00:00'),
  (2, 101, 'Topic', NULL, '2020-04-02 12:00:00');

INSERT INTO polls VALUES (50, 1000, 'poll', 0, 1, 0, 1, NULL, NULL, '2020-03-10', '2020-03-01', '2020-03-10');
INSERT INTO poll_options VALUES (60, 50, 'Yes'), (61, 50, '<strong>No</strong>');
INSERT INTO poll_votes (poll_id, poll_option_id, user_id) VALUES (50, 60, 1), (50, 61, 2);

INSERT INTO discourse_solved_solved_topics (topic_id, answer_post_id) VALUES (101, 1011);

INSERT INTO permalinks (url, topic_id, post_id, category_id, tag_id, external_url) VALUES
  ('old/welcome.html', 100, NULL, NULL, NULL, NULL),
  ('/old/answer', NULL, 1011, NULL, NULL, NULL),
  ('old/elsewhere', NULL, NULL, NULL, NULL, 'https://example.org/');
