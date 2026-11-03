-- A small vBulletin 4 database: the tables and columns the importer reads.

CREATE TABLE user (
  userid int PRIMARY KEY, usergroupid int, membergroupids varchar(250), username varchar(100),
  email varchar(100), joindate int, lastactivity int, homepage varchar(100)
);
CREATE TABLE usergroup (usergroupid int PRIMARY KEY, title varchar(100), description varchar(250));
CREATE TABLE forum (
  forumid int PRIMARY KEY, parentid int, parentlist varchar(250), title varchar(100),
  description text, displayorder int
);
CREATE TABLE thread (
  threadid int PRIMARY KEY, forumid int, title varchar(250), postuserid int, dateline int,
  lastpost int, views int, open tinyint, sticky tinyint, visible tinyint
);
CREATE TABLE post (
  postid int PRIMARY KEY, threadid int, userid int, username varchar(100), dateline int,
  pagetext mediumtext, visible tinyint
);
CREATE TABLE attachment (
  attachmentid int PRIMARY KEY, contentid int, userid int, filedataid int, filename varchar(100)
);
CREATE TABLE filedata (filedataid int PRIMARY KEY, userid int, filedata mediumblob);
CREATE TABLE pmtext (
  pmtextid int PRIMARY KEY, fromuserid int, title varchar(250), message mediumtext, dateline int
);
CREATE TABLE pm (pmid int PRIMARY KEY, pmtextid int, userid int);

INSERT INTO user VALUES
  (1, 6, '', 'Admin', 'admin@example.com', 1262304000, 1700000000, 'https://admin.example.com'),
  (2, 2, '9,12', 'Bob &amp; Sons', 'bob@example.com', 1262390400, 1700000000, '');
INSERT INTO usergroup VALUES (2, 'Registered Users', ''), (9, 'Testers', 'They test.');
INSERT INTO forum VALUES
  (1, -1, '1,-1', 'Main Category', '', 1),
  (2, 1, '2,1,-1', 'General &amp; Chat', '<b>Talk</b> here', 1),
  (3, 2, '3,2,1,-1', 'Off topic', '', 1);
INSERT INTO thread VALUES
  (10, 2, 'Hello &quot;world&quot;', 1, 1262400000, 1262500000, 12, 1, 1, 1),
  (11, 3, 'Closed one', 2, 1262600000, 1262700000, 3, 0, 0, 1),
  (12, 2, 'Moderated', 2, 1262600000, 1262600000, 0, 1, 0, 0);
INSERT INTO post VALUES
  (100, 10, 1, 'Admin', 1262400000, '[B]Hello[/B] everyone [ATTACH=CONFIG]31[/ATTACH]', 1),
  (101, 10, 2, 'Bob &amp; Sons', 1262450000, '[QUOTE=Admin;100]Hello[/QUOTE]\n[FONT=Arial]Hi[/FONT] [HTML]<b>x</b>[/HTML]', 1),
  (102, 10, 0, 'Passer-by', 1262460000, 'A guest', 1),
  (103, 10, 2, 'Bob &amp; Sons', 1262470000, 'Deleted', 2),
  (110, 11, 2, 'Bob &amp; Sons', 1262600000, 'Closed', 1),
  (120, 12, 2, 'Bob &amp; Sons', 1262600000, 'Spam', 0);
INSERT INTO attachment VALUES (31, 100, 1, 31, 'logo.png'), (32, 110, 2, 32, 'notes.txt');
INSERT INTO filedata VALUES (31, 2, NULL), (32, 2, 'Some notes');
INSERT INTO pmtext VALUES (50, 2, 'A question', 'Can you help?', 1262800000);
INSERT INTO pm VALUES (500, 50, 1), (501, 50, 2);
