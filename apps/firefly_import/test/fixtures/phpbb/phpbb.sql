-- A small phpBB 3.3 database: the tables and columns the importer reads,
-- with posts in both of phpBB's storage formats (3.2+'s XML, 3.0's uids).

CREATE TABLE phpbb_config (config_name varchar(255) PRIMARY KEY, config_value varchar(255));
CREATE TABLE phpbb_users (
  user_id int PRIMARY KEY, user_type tinyint, username varchar(255), user_email varchar(100),
  user_regdate int, user_lastvisit int, user_avatar varchar(255), user_avatar_type varchar(255)
);
CREATE TABLE phpbb_groups (
  group_id int PRIMARY KEY, group_type tinyint, group_name varchar(255), group_desc text,
  group_desc_uid varchar(8)
);
CREATE TABLE phpbb_user_group (group_id int, user_id int, group_leader tinyint, user_pending tinyint);
CREATE TABLE phpbb_forums (
  forum_id int PRIMARY KEY, parent_id int, left_id int, forum_type tinyint, forum_name varchar(255),
  forum_desc text, forum_desc_uid varchar(8)
);
CREATE TABLE phpbb_topics (
  topic_id int PRIMARY KEY, forum_id int, topic_title varchar(255), topic_time int, topic_views int,
  topic_status tinyint, topic_type tinyint, topic_visibility tinyint, topic_moved_id int,
  topic_first_post_id int, topic_last_post_time int, poll_start int, poll_length int,
  poll_max_options tinyint
);
CREATE TABLE phpbb_posts (
  post_id int PRIMARY KEY, topic_id int, poster_id int, post_time int, post_text mediumtext,
  bbcode_uid varchar(8), post_edit_time int, post_visibility tinyint, post_username varchar(255)
);
CREATE TABLE phpbb_poll_options (poll_option_id tinyint, topic_id int, poll_option_text text);
CREATE TABLE phpbb_poll_votes (topic_id int, poll_option_id tinyint, vote_user_id int);
CREATE TABLE phpbb_attachments (
  attach_id int PRIMARY KEY, post_msg_id int, in_message tinyint, poster_id int,
  physical_filename varchar(255), real_filename varchar(255)
);
CREATE TABLE phpbb_bookmarks (topic_id int, user_id int);
CREATE TABLE phpbb_privmsgs (
  msg_id int PRIMARY KEY, root_level int, author_id int, message_time int,
  message_subject varchar(255), message_text mediumtext, bbcode_uid varchar(8)
);
CREATE TABLE phpbb_privmsgs_to (msg_id int, user_id int);

INSERT INTO phpbb_config VALUES ('avatar_salt', 'abc123'), ('avatar_path', 'images/avatars/upload');

-- The guest account and a bot aren't imported.
INSERT INTO phpbb_users VALUES
  (1, 2, 'Anonymous', '', 1262304000, 0, '', ''),
  (2, 3, 'Admin &amp; Co', 'admin@example.com', 1262304000, 1700000000, '', ''),
  (3, 0, 'Bob', 'bob@example.com', 1262390400, 1700000000, '', ''),
  (4, 2, 'Googlebot', '', 1262304000, 0, '', '');

INSERT INTO phpbb_groups VALUES
  (1, 3, 'GUESTS', '', ''),
  (7, 0, 'Moderators', '[b:x1y2z3]The[/b:x1y2z3] mods', 'x1y2z3');
INSERT INTO phpbb_user_group VALUES (1, 1, 0, 0), (7, 2, 1, 0), (7, 3, 0, 1);

INSERT INTO phpbb_forums VALUES
  (1, 0, 1, 0, 'Main', '', ''),
  (2, 1, 2, 1, 'Announcements', 'News &amp; updates', ''),
  (3, 1, 4, 2, 'Our website', '', ''),
  (4, 2, 3, 1, 'Archive', '', '');

INSERT INTO phpbb_topics VALUES
  (10, 2, 'Welcome &quot;home&quot;', 1262400000, 99, 0, 1, 1, 0, 100, 1262500000, 1262400000, 0, 2),
  (11, 2, 'Moved here', 1262400000, 0, 0, 0, 1, 10, 0, 0, 0, 0, 0),
  (12, 4, 'Old and locked', 1262600000, 5, 1, 0, 1, 0, 110, 1262700000, 0, 0, 0),
  (13, 2, 'Awaiting approval', 1262600000, 0, 0, 0, 0, 0, 120, 1262600000, 0, 0, 0);

INSERT INTO phpbb_posts VALUES
  (100, 10, 2, 1262400000, '<r><B><s>[b]</s>Hello<e>[/b]</e></B> &amp; welcome!<br/>
<QUOTE author="Bob"><s>[quote=Bob]</s>Hi<e>[/quote]</e></QUOTE>
See <URL url="https://example.com"><s>[url=https://example.com]</s>this<e>[/url]</e></URL> <E>:)</E>
<ATTACHMENT filename="logo.png" index="0"><s>[attachment=0]</s>logo.png<e>[/attachment]</e></ATTACHMENT></r>', '', 1262410000, 1, ''),
  (101, 10, 1, 1262450000, '<t>A guest says hi</t>', '', 0, 1, 'Visitor'),
  (102, 10, 3, 1262460000, '<t>Rude</t>', '', 0, 2, ''),
  (110, 12, 3, 1262600000, '[i:a1b2c3d4]Old[/i:a1b2c3d4] post <!-- s:D --><img src="{SMILIES_PATH}/icon_e_biggrin.gif" alt=":D" title="Very Happy" /><!-- s:D --> at <!-- m --><a class="postlink" href="http://old.example.com/">http://old.example.com/</a><!-- m -->
[list:a1b2c3d4][*:a1b2c3d4]one[/*:m:a1b2c3d4][*:a1b2c3d4]two[/*:m:a1b2c3d4][/list:u:a1b2c3d4]', 'a1b2c3d4', 0, 1, ''),
  (120, 13, 3, 1262600000, '<t>Spam?</t>', '', 0, 0, '');

INSERT INTO phpbb_poll_options VALUES (1, 10, 'Yes'), (2, 10, 'No'), (3, 10, 'Maybe');
INSERT INTO phpbb_poll_votes VALUES (10, 1, 2), (10, 3, 2), (10, 2, 3);

-- Newest first: index 0 is attachment 2 (in the text), index 1 attachment 1.
INSERT INTO phpbb_attachments VALUES
  (1, 100, 0, 2, '2_5d77aa', 'other.png'),
  (2, 100, 0, 2, '2_8a3c1e', 'logo.png'),
  (3, 200, 1, 3, '2_8a3c1e', 'pm.png');

INSERT INTO phpbb_bookmarks VALUES (12, 2);

INSERT INTO phpbb_privmsgs VALUES
  (200, 0, 3, 1262800000, 'Question', '<t>Can you help?</t>', ''),
  (201, 200, 2, 1262900000, 'Re: Question', '<t>Sure.</t>', '');
INSERT INTO phpbb_privmsgs_to VALUES (200, 2), (200, 3), (201, 3), (201, 2);
