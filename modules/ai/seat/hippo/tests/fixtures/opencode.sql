-- OpenCode database fixture: the real schema, rows shaped like real ones.
PRAGMA foreign_keys = OFF;
CREATE TABLE `message` (
          `id` text PRIMARY KEY,
          `session_id` text NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `data` text NOT NULL,
          CONSTRAINT `fk_message_session_id_session_id_fk` FOREIGN KEY (`session_id`) REFERENCES `session`(`id`) ON DELETE CASCADE
        );
CREATE TABLE `part` (
          `id` text PRIMARY KEY,
          `message_id` text NOT NULL,
          `session_id` text NOT NULL,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `data` text NOT NULL,
          CONSTRAINT `fk_part_message_id_message_id_fk` FOREIGN KEY (`message_id`) REFERENCES `message`(`id`) ON DELETE CASCADE
        );
CREATE TABLE `session` (
          `id` text PRIMARY KEY,
          `project_id` text NOT NULL,
          `workspace_id` text,
          `parent_id` text,
          `slug` text NOT NULL,
          `directory` text NOT NULL,
          `path` text,
          `title` text NOT NULL,
          `version` text NOT NULL,
          `share_url` text,
          `summary_additions` integer,
          `summary_deletions` integer,
          `summary_files` integer,
          `summary_diffs` text,
          `metadata` text,
          `cost` real DEFAULT 0 NOT NULL,
          `tokens_input` integer DEFAULT 0 NOT NULL,
          `tokens_output` integer DEFAULT 0 NOT NULL,
          `tokens_reasoning` integer DEFAULT 0 NOT NULL,
          `tokens_cache_read` integer DEFAULT 0 NOT NULL,
          `tokens_cache_write` integer DEFAULT 0 NOT NULL,
          `revert` text,
          `permission` text,
          `agent` text,
          `model` text,
          `time_created` integer NOT NULL,
          `time_updated` integer NOT NULL,
          `time_compacting` integer,
          `time_archived` integer,
          CONSTRAINT `fk_session_project_id_project_id_fk` FOREIGN KEY (`project_id`) REFERENCES `project`(`id`) ON DELETE CASCADE
        );
INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated) VALUES ('ses_fixture_main', 'proj', NULL, 'slug', '/home/bridge', 'Fix the fence gate', '1', 1791302400000, 1791302400000);
INSERT INTO session (id, project_id, parent_id, slug, directory, title, version, time_created, time_updated) VALUES ('ses_fixture_sub', 'proj', 'ses_fixture_main', 'slug', '/home/bridge', 'Subagent search', '1', 1791302405000, 1791302405000);
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg_1', 'ses_fixture_main', 1791302401000, 1791302401000, '{"role": "user", "time": {"created": 1791302401000}, "agent": "build", "model": {"providerID": "openai", "modelID": "gpt-5.6-sol"}, "summary": {"diffs": []}}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_1', 'msg_1', 'ses_fixture_main', 1791302401000, 1791302401000, '{"type": "text", "text": "Fix the fence gate."}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_1s', 'msg_1', 'ses_fixture_main', 1791302401000, 1791302401000, '{"type": "text", "text": "injected synthetic context", "synthetic": true}');
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg_2', 'ses_fixture_main', 1791302402000, 1791302402000, '{"parentID": "msg_1", "role": "assistant", "mode": "build", "agent": "build", "path": {"cwd": "/home/bridge", "root": "/"}, "cost": 0, "tokens": {"total": 26902, "input": 2551, "output": 178, "reasoning": 109, "cache": {"write": 0, "read": 24064}}, "modelID": "gpt-5.6-sol", "providerID": "openai", "time": {"created": 1791302402000, "completed": 1791302403000}, "finish": "tool-calls"}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_2a', 'msg_2', 'ses_fixture_main', 1791302402000, 1791302402000, '{"type": "step-start"}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_2b', 'msg_2', 'ses_fixture_main', 1791302402000, 1791302402000, '{"type": "reasoning", "text": "private"}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_2c', 'msg_2', 'ses_fixture_main', 1791302402100, 1791302402100, '{"type": "tool", "tool": "bash", "callID": "call_G", "state": {"status": "completed", "input": {"command": "ls gate"}, "output": "hinge.txt", "title": "ls", "metadata": {}, "time": {"start": 1791302402100, "end": 1791302402200}}, "metadata": {"openai": {"itemId": "fc_02ee00be6188ff7d016a59506d873481978d83e69a9261c702"}}}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_2d', 'msg_2', 'ses_fixture_main', 1791302402900, 1791302402900, '{"type": "step-finish", "reason": "tool-calls"}');
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg_3', 'ses_fixture_main', 1791302404000, 1791302404000, '{"parentID": "msg_1", "role": "assistant", "mode": "build", "agent": "build", "path": {"cwd": "/home/bridge", "root": "/"}, "cost": 0, "tokens": {"total": 26902, "input": 2551, "output": 178, "reasoning": 109, "cache": {"write": 0, "read": 24064}}, "modelID": "gpt-5.6-sol", "providerID": "openai", "time": {"created": 1791302404000, "completed": 1791302404500}, "finish": "stop"}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_3', 'msg_3', 'ses_fixture_main', 1791302404000, 1791302404000, '{"type": "text", "text": "The gate hinge is replaced."}');
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg_s1', 'ses_fixture_sub', 1791302405000, 1791302405000, '{"role": "user", "time": {"created": 1791302401000}, "agent": "build", "model": {"providerID": "openai", "modelID": "gpt-5.6-sol"}, "summary": {"diffs": []}}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_s1', 'msg_s1', 'ses_fixture_sub', 1791302405000, 1791302405000, '{"type": "text", "text": "Search for hinges."}');
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg_4', 'ses_fixture_main', 1791302406000, 1791302406000, '{"role": "user", "time": {"created": 1791302406000}, "agent": "build", "model": {"providerID": "openai", "modelID": "gpt-5.6-sol"}, "summary": {"diffs": []}}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_4', 'msg_4', 'ses_fixture_main', 1791302406000, 1791302406000, '{"type": "text", "text": "Paint it too."}');
INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES ('msg_5', 'ses_fixture_main', 1791302407000, 1791302407000, '{"parentID": "msg_f6ce21fba001KGuWmPiUaFAvpw", "role": "assistant", "mode": "build", "agent": "build", "path": {"cwd": "/home/bridge", "root": "/"}, "cost": 0, "tokens": {"total": 26902, "input": 2551, "output": 178, "reasoning": 109, "cache": {"write": 0, "read": 24064}}, "modelID": "gpt-5.6-sol", "providerID": "openai", "time": {"created": 1791302407000}}');
INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES ('prt_5', 'msg_5', 'ses_fixture_main', 1791302407000, 1791302407000, '{"type": "text", "text": "Painting (still streaming)"}');
