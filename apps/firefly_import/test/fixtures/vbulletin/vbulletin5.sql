-- A small vBulletin 5 database: everything is a node.

CREATE TABLE user (
  userid int PRIMARY KEY, usergroupid int, membergroupids varchar(250), username varchar(100),
  email varchar(100), joindate int, lastactivity int, homepage varchar(100)
);
CREATE TABLE usergroup (usergroupid int PRIMARY KEY, title varchar(100), description varchar(250));
CREATE TABLE contenttype (contenttypeid int PRIMARY KEY, class varchar(50));
CREATE TABLE node (
  nodeid int PRIMARY KEY, parentid int, contenttypeid int, title varchar(250), description text,
  userid int, authorname varchar(100), publishdate int, unpublishdate int, lastcontent int,
  starter int, displayorder int, open tinyint, sticky tinyint, approved tinyint,
  showpublished tinyint, deleteuserid int
);
CREATE TABLE closure (parent int, child int, depth int);
CREATE TABLE channel (nodeid int PRIMARY KEY, guid varchar(150));
CREATE TABLE text (nodeid int PRIMARY KEY, rawtext mediumtext);
CREATE TABLE attach (nodeid int PRIMARY KEY, filedataid int, filename varchar(255));
CREATE TABLE filedata (filedataid int PRIMARY KEY, userid int, filedata mediumblob);
CREATE TABLE privatemessage (nodeid int PRIMARY KEY, msgtype varchar(20));
CREATE TABLE sentto (nodeid int, userid int);

INSERT INTO user VALUES
  (1, 6, '', 'Admin', 'admin@example.com', 1262304000, 1700000000, ''),
  (2, 2, '', 'Bob', 'bob@example.com', 1262390400, 1700000000, '');
INSERT INTO usergroup VALUES (2, 'Registered Users', '');
INSERT INTO contenttype VALUES (23, 'Channel'), (22, 'Text'), (24, 'Attach'), (25, 'PrivateMessage');

-- 1 the root, 2 the forum root, 3 a category, 4 a forum in it, 5 the
-- private messages' channel.
INSERT INTO node VALUES
  (1, 0, 23, 'Root', '', 1, 'Admin', 1262304000, 0, 0, 1, 0, 1, 0, 1, 1, 0),
  (2, 1, 23, 'Forum', '', 1, 'Admin', 1262304000, 0, 0, 2, 0, 1, 0, 1, 1, 0),
  (3, 2, 23, 'Main Category', '', 1, 'Admin', 1262304000, 0, 0, 3, 1, 1, 0, 1, 1, 0),
  (4, 3, 23, 'General', 'Talk here', 1, 'Admin', 1262304000, 0, 0, 4, 1, 1, 0, 1, 1, 0),
  (5, 1, 23, 'Private Messages', '', 1, 'Admin', 1262304000, 0, 0, 5, 0, 1, 0, 1, 1, 0),
  (10, 4, 22, 'First topic', '', 1, 'Admin', 1262400000, 0, 1262500000, 10, 0, 1, 1, 1, 1, 0),
  (11, 10, 22, '', '', 2, 'Bob', 1262450000, 0, 0, 10, 0, 1, 0, 1, 1, 0),
  (12, 11, 22, '', '', 1, 'Admin', 1262460000, 0, 0, 10, 0, 1, 0, 1, 1, 0),
  (13, 10, 22, '', '', 2, 'Bob', 1262470000, 1262480000, 0, 10, 0, 1, 0, 1, 0, 1),
  (14, 10, 24, '', '', 1, 'Admin', 1262400000, 0, 0, 10, 0, 1, 0, 1, 1, 0),
  (20, 5, 22, 'Hi Bob', '', 1, 'Admin', 1262800000, 0, 0, 20, 0, 1, 0, 1, 1, 0),
  (21, 20, 22, '', '', 2, 'Bob', 1262900000, 0, 0, 20, 0, 1, 0, 1, 1, 0);
INSERT INTO closure VALUES
  (1, 1, 0), (1, 2, 1), (1, 3, 2), (1, 4, 3), (2, 2, 0), (2, 3, 1), (2, 4, 2), (3, 3, 0),
  (3, 4, 1), (4, 4, 0), (1, 5, 1), (5, 5, 0);
INSERT INTO channel VALUES
  (1, 'vbulletin-4ecbdf567f2c35.70389589'), (2, 'vbulletin-4ecbdf567f2c35.70389590'),
  (3, 'c3'), (4, 'c4'), (5, 'vbulletin-4ecbdf567f2c35.70389595');
INSERT INTO text VALUES
  (10, '[B]Welcome[/B] [ATTACH=JSON]{"data-attachmentid":14,"data-align":"none"}[/ATTACH]'),
  (11, '[QUOTE=Admin;n10]Welcome[/QUOTE]Thanks'),
  (12, 'A comment'),
  (13, 'Removed'),
  (20, 'Hello Bob'),
  (21, 'Hi!');
INSERT INTO attach VALUES (14, 7, 'logo.png');
INSERT INTO filedata VALUES (7, 1, NULL);
INSERT INTO privatemessage VALUES (20, 'message'), (21, 'message');
INSERT INTO sentto VALUES (20, 1), (20, 2);
