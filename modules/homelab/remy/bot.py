"""The family's household chat bot.

Two rooms with room-scoped skills:

  - "Household": lists and dated to-dos in plain language, a 07:00
    morning plan and 19:00 evening report, folding in the family calendar
    from calendar.json, which the separate remy-calendar-sync unit writes.

  - "Scratchpad": the same skills against its own scratch.db, with the
    calendar read-only and no scheduled posts.

Chat text is untrusted: the model only classifies it into a fixed
per-room intent schema, SQL is parameterized from typed fields, and there
is no path from a message to a shell or to Matrix admin. Parsing runs on
the local GPU.
"""

import asyncio
import html
import json
import logging
import os
import re
import sqlite3
import subprocess
import time
from datetime import date, datetime, timedelta
from functools import partial
from zoneinfo import ZoneInfo

import requests
from nio import AsyncClient, RoomMessageText

log = logging.getLogger("remy")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

HS_URL = os.environ["BOT_HS_URL"]
USER_ID = os.environ["MATRIX_USER"]
PASSWORD = os.environ["MATRIX_PASSWORD"]
INVITE_USERS = [u for u in os.environ.get("BOT_INVITE_USERS", "").split(",") if u]
ROOM_NAME = "Household"
SCRATCH_ROOM_NAME = "Scratchpad"
SCRATCH_USERS = [u for u in os.environ.get("BOT_SCRATCH_USERS", "").split(",") if u]
SCRATCH_DB_PATH = os.environ.get("BOT_SCRATCH_DB", "/var/lib/remy/scratch.db")
LLM_URL = os.environ.get("LLM_URL", "http://127.0.0.1:8091/v1/chat/completions")
LLM_MODEL = os.environ.get("LLM_MODEL", "qwen3.6-35b-a3b")
DB_PATH = os.environ.get("BOT_DB", "/var/lib/remy/home.db")
CAL_PATH = os.environ.get("BOT_CALENDAR_JSON", "/var/lib/remy/calendar.json")
TZ = ZoneInfo(os.environ.get("BOT_TZ", "America/New_York"))
MORNING = os.environ.get("BOT_MORNING", "07:00")
EVENING = os.environ.get("BOT_EVENING", "19:00")
# An append-only journal written once a day into the state dir; a separate
# unit mirrors it into the vault, since this process cannot reach /home.
LOG_PATH = os.path.join(os.path.dirname(DB_PATH), "log.md")
LOG_TIME = os.environ.get("BOT_LOG_TIME", "23:50")

START_MS = int(time.time() * 1000)



class Conn(sqlite3.Connection):
    # Whether this database may write to the family calendar. False for the
    # scratchpad, where everything downstream of queue_cal no-ops.
    cal = True


def connect(path):
    # check_same_thread=False: parsing reads via asyncio.to_thread while the
    # event loop owns writes. CPython's sqlite3 is built in serialized
    # threading mode, so one connection across threads is safe.
    db = sqlite3.connect(path, check_same_thread=False, factory=Conn)
    db.row_factory = sqlite3.Row
    return db


def home_db(path=DB_PATH, cal=True):
    # The scratchpad reuses this schema against its own file.
    db = connect(path)
    db.cal = cal
    db.executescript("""
        CREATE TABLE IF NOT EXISTS task(
            id INTEGER PRIMARY KEY,
            title TEXT NOT NULL,
            due TEXT NOT NULL DEFAULT '',   -- ISO yyyy-mm-dd, '' = undated
            assignee TEXT NOT NULL DEFAULT '',  -- '' = whole household
            created_by TEXT NOT NULL,
            created_ts INTEGER NOT NULL,
            done_ts INTEGER,                -- NULL = open
            done_by TEXT NOT NULL DEFAULT '',
            deleted INTEGER NOT NULL DEFAULT 0  -- soft delete: recoverable
        );
        CREATE TABLE IF NOT EXISTS item(
            id INTEGER PRIMARY KEY,
            list_name TEXT NOT NULL,
            name TEXT NOT NULL,
            seq INTEGER NOT NULL DEFAULT 0, -- per-list display number, stable
            due TEXT NOT NULL DEFAULT '',       -- ISO yyyy-mm-dd, '' = undated
            assignee TEXT NOT NULL DEFAULT '',  -- '' = whole household
            section TEXT NOT NULL DEFAULT '',   -- a labelled group within a list
            added_by TEXT NOT NULL,
            added_ts INTEGER NOT NULL,
            done_ts INTEGER,                -- NULL = still needed
            done_by TEXT NOT NULL DEFAULT '',
            deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS log_note(
            id INTEGER PRIMARY KEY,
            day TEXT NOT NULL,              -- yyyy-mm-dd this note belongs to
            text TEXT NOT NULL,
            added_by TEXT NOT NULL,
            added_ts INTEGER NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS cal_outbox(
            id INTEGER PRIMARY KEY,
            op TEXT NOT NULL DEFAULT 'create',  -- create | delete
            uid TEXT NOT NULL DEFAULT '',   -- iCalendar UID (deterministic for mirrors)
            summary TEXT NOT NULL,
            start TEXT NOT NULL,            -- 'yyyy-mm-dd HH:MM' or all-day 'yyyy-mm-dd'
            created_by TEXT NOT NULL,
            created_ts INTEGER NOT NULL,
            pushed_ts INTEGER,              -- NULL = awaiting the sync unit
            error TEXT NOT NULL DEFAULT ''
        );
        CREATE TABLE IF NOT EXISTS reminder(
            id INTEGER PRIMARY KEY,
            text TEXT NOT NULL,
            at TEXT NOT NULL,               -- local 'yyyy-mm-dd HH:MM'
            repeat TEXT NOT NULL DEFAULT '', -- '' one-shot; 'daily' or 'mon,thu'
            assignee TEXT NOT NULL DEFAULT '',  -- '' = whole household
            created_by TEXT NOT NULL,
            created_ts INTEGER NOT NULL,
            fired_ts INTEGER,               -- NULL = pending; recurring: last fired
            deleted INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS processed(event_id TEXT PRIMARY KEY, ts INTEGER);
        CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT);
    """)
    # Migrations for databases created before these columns existed.
    if "assignee" not in [r[1] for r in db.execute("PRAGMA table_info(task)")]:
        db.execute("ALTER TABLE task ADD COLUMN assignee TEXT NOT NULL DEFAULT ''")
    outbox_cols = [r[1] for r in db.execute("PRAGMA table_info(cal_outbox)")]
    if "op" not in outbox_cols:
        db.execute("ALTER TABLE cal_outbox ADD COLUMN op TEXT NOT NULL DEFAULT 'create'")
        db.execute("ALTER TABLE cal_outbox ADD COLUMN uid TEXT NOT NULL DEFAULT ''")
    # A to-do is just a list item that may carry a due date, so to-dos live in
    # a list called "to-dos" rather than a separate table.
    item_cols = [r[1] for r in db.execute("PRAGMA table_info(item)")]
    for col in ("due", "assignee", "section", "done_by"):
        if col not in item_cols:
            db.execute(f"ALTER TABLE item ADD COLUMN {col} TEXT NOT NULL DEFAULT ''")
    if "seq" not in item_cols:
        db.execute("ALTER TABLE item ADD COLUMN seq INTEGER NOT NULL DEFAULT 0")
    # An event is marked 'seen' before its handler runs and 'done' after, so
    # a row stuck at 'seen' is a crash mid-handling, reported rather than
    # replayed on the next start. Rows predating the column were completed.
    if "repeat" not in [r[1] for r in db.execute("PRAGMA table_info(reminder)")]:
        db.execute("ALTER TABLE reminder ADD COLUMN repeat TEXT NOT NULL DEFAULT ''")
    processed_cols = [r[1] for r in db.execute("PRAGMA table_info(processed)")]
    if "status" not in processed_cols:
        db.execute("ALTER TABLE processed ADD COLUMN status TEXT NOT NULL DEFAULT 'done'")
        db.execute("ALTER TABLE processed ADD COLUMN body TEXT NOT NULL DEFAULT ''")
        db.execute("ALTER TABLE processed ADD COLUMN room TEXT NOT NULL DEFAULT ''")
    db.commit()
    if meta_get(db, "merged_v2") != "1":
        for t in db.execute("SELECT * FROM task").fetchall():
            db.execute(
                "INSERT INTO item(list_name,name,due,assignee,section,added_by,"
                "added_ts,done_ts,done_by,deleted) VALUES('to-dos',?,?,?,'',?,?,?,?,?)",
                (t["title"], t["due"], t["assignee"], t["created_by"], t["created_ts"],
                 t["done_ts"], t["done_by"], t["deleted"]))
            new_id = db.execute("SELECT last_insert_rowid() r").fetchone()["r"]
            # An open dated to-do already has a calendar mirror under its
            # task uid; move it to the item uid so edits stay in sync.
            if db.cal and not t["deleted"] and t["done_ts"] is None and t["due"]:
                queue_cal(db, "delete", task_uid(t["id"]))
                queue_cal(db, "create", item_uid(new_id),
                          f"☐ {t['title']}" + (f" — {t['assignee']}" if t["assignee"] else ""),
                          t["due"], t["created_by"])
        meta_set(db, "merged_v2", "1")
    db.commit()
    # Open items are numbered 1..N per list so the display is gap-free.
    # Recomputed at every start, and by the handlers after each change;
    # retired rows get 0 so they never collide.
    db.execute("UPDATE item SET seq = (SELECT COUNT(*) FROM item i2 "
               "WHERE i2.list_name = item.list_name AND i2.deleted=0 "
               "AND i2.done_ts IS NULL AND i2.id <= item.id) "
               "WHERE deleted=0 AND done_ts IS NULL")
    db.execute("UPDATE item SET seq=0 WHERE deleted=1 OR done_ts IS NOT NULL")
    db.commit()
    return db


def meta_get(db, k):
    row = db.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return row["v"] if row else None


def meta_set(db, k, v):
    db.execute("INSERT INTO meta(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, v))
    db.commit()


# The Matrix session lives in its own 0600 file rather than the database:
# every mutation dumps the database into the git history repo, so a
# credential there would be a credential in immutable history. run()
# invalidates any token found in an old database.
SESSION_PATH = os.path.join(os.path.dirname(DB_PATH), "session.json")


def load_session():
    try:
        with open(SESSION_PATH) as f:
            sess = json.load(f)
        return sess["access_token"], sess["device_id"]
    except (OSError, ValueError, KeyError):
        return None, None


def save_session(token, device):
    fd = os.open(SESSION_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"access_token": token, "device_id": device}, f)


def git_snapshot(db, db_path, reason):
    """Commit a full SQL dump of a database to a git repo next to it.

    Every mutation lands as one commit, so any past state is one
    `git show`/`git checkout` away even if a bug (or a mis-parsed message)
    mangles the live database. Failures are logged, never fatal — history
    is a safety net, not a dependency.
    """
    try:
        hist = os.path.join(os.path.dirname(db_path), "history")
        os.makedirs(hist, exist_ok=True)
        if not os.path.isdir(os.path.join(hist, ".git")):
            subprocess.run(["git", "init", "-q"], cwd=hist, check=True)
        # home.db and scratch.db share /var/lib/remy/history under their
        # own names.
        name = os.path.basename(db_path).replace(".db", ".sql")
        with open(os.path.join(hist, name), "w") as f:
            for line in db.iterdump():
                # Guards against a credential row regressing into meta and
                # reaching git history.
                if line.startswith("INSERT INTO") and "meta" in line[:30] and (
                        "access_token" in line or "device_id" in line):
                    continue
                f.write(line + "\n")
        subprocess.run(["git", "add", name], cwd=hist, check=True)
        subprocess.run(
            ["git", "-c", "user.name=remy", "-c", "user.email=remy@localhost",
             "commit", "-q", "-m", reason, "--allow-empty-message"],
            cwd=hist, check=False)  # nothing-to-commit is fine
    except Exception:
        log.exception("git snapshot failed")


def today():
    return datetime.now(TZ).date()



def llm_call(system, text, schema, max_tokens=800):
    body = {
        "model": LLM_MODEL,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": text}],
        "response_format": {"type": "json_schema",
                            "json_schema": {"name": "action", "schema": schema}},
        # No thinking for a classification call: reasoning tokens count
        # against max_tokens and can starve the JSON entirely.
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0.1,
        "max_tokens": max_tokens,
    }
    resp = requests.post(LLM_URL, json=body, timeout=180)
    resp.raise_for_status()
    content = resp.json()["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", content, re.S)
    return json.loads(m.group(0) if m else content)


def llm_text(system, text, max_tokens=700):
    """Free-form completion (no JSON schema) — used only to compose the daily
    log's prose. A little warmth is welcome here, so temperature is higher
    than the classifier's; callers must tolerate failure (the log falls back
    to a deterministic scaffold)."""
    body = {
        "model": LLM_MODEL,
        "messages": [{"role": "system", "content": system},
                     {"role": "user", "content": text}],
        "chat_template_kwargs": {"enable_thinking": False},
        "temperature": 0.3,
        "max_tokens": max_tokens,
    }
    resp = requests.post(LLM_URL, json=body, timeout=180)
    resp.raise_for_status()
    return resp.json()["choices"][0]["message"]["content"]


# Lists, dated to-dos, and the scheduled day posts.

def open_items(db, list_name=None):
    """Open (undone, undeleted) items, optionally in one list. Dated items
    sort before undated within a list; sections group together."""
    q = "SELECT * FROM item WHERE deleted=0 AND done_ts IS NULL"
    args = ()
    if list_name is not None:
        q += " AND list_name=?"
        args = (list_name,)
    q += " ORDER BY list_name, section, CASE WHEN due='' THEN 1 ELSE 0 END, due, id"
    return db.execute(q, args).fetchall()


def dated_open(db):
    """Every open dated item, across all lists — the day's real commitments."""
    return db.execute(
        "SELECT * FROM item WHERE deleted=0 AND done_ts IS NULL AND due!='' "
        "ORDER BY due, id").fetchall()


def fmt_due(due):
    if not due:
        return ""
    d = date.fromisoformat(due)
    delta = (d - today()).days
    nice = d.strftime("%a %b %-d")
    if delta < 0:
        return f" (was due {nice})"
    if delta == 0:
        return " (today)"
    if delta == 1:
        return " (tomorrow)"
    return f" (by {nice})"


# Localparts of the invited accounts: the names the parser may assign to.
FAMILY = [u.split(":")[0].lstrip("@") for u in INVITE_USERS]


def fmt_who(r):
    return f" — {r['assignee']}" if r["assignee"] else ""


def fmt_item(r):
    # Per-list numbering, used only in single-list views.
    return f"{r['seq']}. {r['name']}{fmt_who(r)}{fmt_due(r['due'])}"


def calendar_events(day_from, day_to):
    """Events with a start date in [day_from, day_to], from the sync file.

    Returns (events, note): events sorted by start; note is a staleness
    warning string or "". Missing/broken file = no events, no crash — the
    calendar section simply doesn't render.
    """
    try:
        with open(CAL_PATH) as f:
            data = json.load(f)
    except Exception:
        return [], ""
    out = []
    for ev in data.get("events", []):
        # Mirror-events exist for the phone apps; the posts already render
        # them as tasks and reminders.
        uid = ev.get("uid", "")
        if (uid.startswith("remy-task-") or uid.startswith("remy-rem-")
                or uid.startswith("remy-item-")):
            continue
        try:
            d = date.fromisoformat(ev["start"][:10])
        except Exception:
            continue
        if day_from <= d <= day_to:
            out.append(ev)
    out.sort(key=lambda e: e["start"])
    # The source tag is only useful with several named calendars.
    if len({e.get("calendar") for e in out}) <= 1:
        out = [{**e, "calendar": ""} for e in out]
    note = ""
    fetched = data.get("fetched_at", 0)
    if fetched and time.time() - fetched > 24 * 3600:
        note = "(calendar last synced >1 day ago)"
    return out, note


def fmt_event(ev):
    start = ev["start"]
    if len(start) > 10:  # datetime, not all-day
        when = datetime.fromisoformat(start).astimezone(TZ).strftime("%-H:%M")
    else:
        when = "all day"
    who = f" — {ev['calendar']}" if ev.get("calendar") else ""
    return f"{when}  {ev.get('summary', '(untitled)')}{who}"


HOME_ACTION = {
    "type": "object",
    "properties": {
        "intent": {"type": "string",
                   "enum": ["item_add", "item_done", "item_edit", "item_remove",
                            "item_restore", "list_show", "lists_show",
                            "list_rename", "list_clear", "todos_show",
                            "remind_add", "remind_cancel", "remind_show",
                            "cal_add", "log_add", "post_now", "help", "ask",
                            "other"]},
        "items": {"type": "array", "items": {"type": "string"}},
        "list_name": {"type": "string"},
        "new_list_name": {"type": "string"},
        "section": {"type": "string"},
        "due": {"type": "string"},
        "at": {"type": "string"},
        "repeat": {"type": "string"},
        "rem_id": {"type": "integer"},
        "assignee": {"type": "string"},
        "item_id": {"type": "integer"},
        "new_name": {"type": "string"},
        "new_due": {"type": "string"},
        "new_assignee": {"type": "string"},
        "scope": {"type": "string",
                  "enum": ["today", "week", "all", "overdue", "done", ""]},
        "kind": {"type": "string", "enum": ["morning", "evening", "week", ""]},
        "text": {"type": "string"},
        "reply": {"type": "string"},
    },
    # Every field is required: a grammar-constrained model never emits
    # optional ones. Unused fields carry "", 0 or [].
    "required": ["intent", "items", "list_name", "new_list_name", "section",
                 "due", "at", "repeat", "rem_id", "assignee", "item_id",
                 "new_name", "new_due", "new_assignee", "scope", "kind",
                 "text", "reply"],
}

# One message can carry several actions.
HOME_SCHEMA = {
    "type": "object",
    "properties": {
        "actions": {"type": "array", "items": HOME_ACTION, "minItems": 1},
    },
    "required": ["actions"],
}


def home_parse(db, sender_name, text):
    now_dt = datetime.now(TZ)
    now = now_dt.date()
    # The model sees each item under the same per-list number the user
    # sees, so it can route and reference them.
    lists = {}
    for r in open_items(db):
        lists.setdefault(r["list_name"], []).append(r)
    if lists:
        listing = "\n".join(
            f"{ln}:\n" + "\n".join(f"  {r['seq']}. {r['name']}{fmt_who(r)}{fmt_due(r['due'])}"
                                   for r in rows)
            for ln, rows in lists.items())
    else:
        listing = "(no lists yet)"
    list_names = ", ".join(lists.keys()) or "(none yet)"
    deleted = "\n".join(f"[{r['list_name']}] {r['name']}" for r in db.execute(
        "SELECT * FROM item WHERE deleted=1 ORDER BY id DESC LIMIT 5"))
    reminders = "\n".join(fmt_reminder(r) for r in pending_reminders(db)) or "(none)"
    chat_desc = ("family household-organizer chat" if db.cal else
                 "personal scratchpad chat (one person and the bot: quick "
                 "notes, reminders, to-dos, lists)")
    cal_rule = """- An APPOINTMENT/EVENT that happens at a set time ("put the dentist on the
  calendar tuesday at 3", "gab's recital friday", "dinner with the smiths
  saturday 7pm") => cal_add with text = a short title and at ('yyyy-mm-dd HH:MM',
  or just 'yyyy-mm-dd' for all-day). Calendar = something HAPPENING at a time; a
  to-do = something to DO (maybe by a day); a reminder = a ping.
- "add to log ..." / "log that ..." / "for the log, ..." / "note in the log"
  => log_add with text = the thing to record (a vibe, a funny moment, something
  that happened today). The log is the family's daily journal.""" if db.cal else """- The calendar is READ-ONLY here (it shows in summaries, but events are added
  in the Household room): an appointment ("dentist tuesday at 3") => item_add
  to list "to-dos" with its due date, never cal_add. A keep-this jot ("note: the
  wifi password is X") => item_add with list_name "notes". "add to log" => log_add
  is a Household feature; here just item_add to "notes"."""
    system = f"""You classify one message from a {chat_desc} into a JSON list of actions.
A message may contain SEVERAL actions ("get milk, and remind me to call the vet
thursday" = item_add + remind_add) — emit one action object per thing, in message
order. Most messages are exactly one action.
Today is {now.isoformat()} ({now.strftime('%A')}) and the time right now is
{now_dt.strftime('%H:%M')} (24h) — resolve relative times ("in 5 minutes", "in an
hour") from that. Message author: {sender_name}. Family: [{", ".join(FAMILY)}].

The world is THREE buckets: LISTS (any number of named lists — shopping, chores,
to-dos, packing…; items may carry a due date and a person), the CALENDAR (timed
appointments), and REMINDERS (pings at a moment). "to-dos" is the catch-all list
for things to do; "chores" is its own list.

GUIDING PRINCIPLE — breadth by default: the vaguer the request, the BROADER the
answer. A non-specific ask ("what's going on", "what do I have", "the agenda",
"tasks") should return the widest view — todos_show at scope "all", which shows
the whole to-do list plus the calendar and reminders. NARROW only when the
message itself is specific: a named list, a named person, a specific day/week,
or "what got done". When unsure how wide to go, go wider — show more, not less.

Open lists (each item shown as its per-list number — numbers restart per list,
so "2" in shopping is a different item than "2" in chores):
{listing}
Existing list names: {list_names}
Recently removed items (restorable), shown as [list] name:
{deleted or "(none)"}
Pending reminders (time text):
{reminders}

Rules:
- Weeks run Monday–Sunday. "this week" = through the coming Sunday (inclusive);
  "next week" = the following Monday–Sunday; "the weekend" = the coming Sat/Sun.
- ADDING to a list ("add milk and eggs to shopping", "put batteries on the
  hardware list", "we need to renew the registration by friday", "dylan should
  call the plumber thursday", "remember to water the plants") => item_add.
  Fields: list_name (short, lowercase — reuse an existing name above when it
  fits); items = each thing separately, short, no dates/names inside; due as ISO
  yyyy-mm-dd if a day was given (today/tomorrow/EOD=today, a weekday = the NEXT
  such day, "" if none); assignee = a Family name ONLY when the item is
  explicitly directed at a specific NAMED person ("dylan needs to X", "gab
  should X", "for dylan") — NEVER for "I"/"me"/"my"/"we"/"us" or when no person
  is named; those are "" (whole household). section (lowercase) only if they
  put it in a named part of the list (e.g. recurring chores => list "chores"
  section "recurring"), else "".
  ROUTING: groceries/food with no list named => list_name "shopping"; a plain
  "we need to X" / "don't forget to X" / "add X" to-do with no list named =>
  list_name "to-dos". If a thing could sensibly go on more than one existing
  list and none was named, DO NOT GUESS — use intent ask (see below).
- Starting an empty list ("make a packing list") => item_add, that list_name,
  items [].
- REFERENCING an item: numbers are PER-LIST, so to act on one you MUST give BOTH
  its list_name AND item_id = its number within that list (from the lists above).
  Find it by name ("got the milk" => milk's list + its number) or by "N on/in
  <list>" ("done 2 on shopping" => list_name "shopping", item_id 2). If only a
  bare number is given and more than one list has it, DO NOT guess — use ask.
- Checking an item off ("got the milk", "did the plumber thing", "done 2 on
  shopping") => item_done with list_name + item_id.
- Rewording/redating/reassigning/moving ("push the dentist to friday", "give the
  milk to gab") => item_edit with list_name + item_id and only the changed
  new_name/new_due/new_assignee. Removing one => item_remove with list_name +
  item_id. Bringing one back ("restore the milk", "undo that") => item_restore
  with new_name = the removed item's name (from the removed list above) and
  list_name if a list was named — removed items are referenced by NAME, not a
  number.
- MANAGING lists: "show the shopping list" / "what's on chores" => list_show
  with list_name. "what lists do we have" / "show all my lists" => lists_show.
  "rename hardware to garage" => list_rename with list_name + new_list_name.
  "clear/delete the shopping list" => list_clear + list_name.
- Wanting a PING at a set moment ("remind me at 5 to leave", "remind us thursday
  at 9am to put the bins out") => remind_add with title... use field "text" for
  the thing (short) and at as 'yyyy-mm-dd HH:MM' 24h local (resolve like due
  dates; morning=09:00, noon=12:00, afternoon=15:00, evening/tonight=19:00; bare
  "at 5" after noon = 17:00). assignee like items: ONLY a Family name when the
  reminder is explicitly for a specific NAMED person ("remind dylan to X", "a
  reminder that gab needs to X") — "remind me"/"remind us"/"remind everyone"
  ALL get assignee "" (no tag). RECURRING pings ("remind me every day at 10
  to take my meds", "every tuesday at 10am", "every monday to friday at 8 put
  the bins out", "daily at 9") => remind_add with repeat = "daily" or a comma
  list of weekdays ("tue"; "mon,tue,wed,thu,fri") and at = the first upcoming
  occurrence; one-time reminders get repeat "". Other cadences (monthly, every
  other week, hourly) are NOT supported — use ask to say so rather than
  faking one. A DAY deadline with no clock
  time ("by friday") is an item_add to "to-dos", NOT a reminder. Cancelling
  ("cancel the csa reminder", "never mind that reminder", "stop reminding me
  about the bins" — how a recurring one ends) => remind_cancel with
  text = words from the reminder to match (leave "" only if there is exactly
  one pending). "what reminders are set" / "my reminders today" / "reminders
  this week" => remind_show with scope (today|week|all).
{cal_rule}
- AGENDA / OVERVIEW — this is the answer to almost every "what's going on" ask:
  "what do I have to do", "what's to do", "what's the task(s)", "what's on my
  plate", "what's on the agenda", "what's today", "what's going on today/this
  week", "what's the day/week look like", "show my to-dos", "the to-do list",
  even "what's on the calendar" => todos_show. ONE view that pulls ALL THREE
  buckets together: the full to-do list, the week's calendar, and reminders.
  scope: DEFAULT "all" (the whole picture); use "today" only if they clearly
  bound it to today, "week" for this/next week, "done" for "what got done".
  assignee only when a person is named ("what does gab have"); "what do I have"
  = the author. Do NOT use post_now for these.
- Only an explicit ask for a scheduled DIGEST ("give me the morning plan/
  summary", "the evening report", "the week ahead") => post_now with kind
  (morning|evening|week).
- Asking what you can do => help.
- UNSURE? If you genuinely cannot tell which list an item belongs to, or which
  item/list a command targets, DO NOT guess and DO NOT invent — use intent ask
  with reply = one short clarifying question ("Which list should 'gym bag' go
  on — packing, or to-dos?"). Prefer asking over a wrong guess.
- Anything else (greetings, chatter between the humans, unclear and not for the
  bot) => intent other with reply = a one-line response ONLY if the message was
  addressed to the bot, else reply "".
Every JSON field is required in every action: set unused string fields to "",
unused numbers to 0, unused arrays to []. For item_add, items MUST be filled in
(unless starting an empty list). Chatter not addressed to the bot = one "other"
action with reply "".
Output only the JSON object: {{"actions": [...]}}."""
    # Several actions times all-required fields; local tokens are free.
    return llm_call(system, text, HOME_SCHEMA, max_tokens=2000).get("actions", [])


def valid_date(s):
    try:
        date.fromisoformat(s)
        return s
    except (ValueError, TypeError):
        return ""


def valid_assignee(s):
    s = (s or "").strip().lower()
    return s if s in FAMILY else ""



def pending_reminders(db):
    # A recurring reminder is always pending: firing rolls its `at` forward
    # and stamps fired_ts with the last fire instead of retiring the row.
    return db.execute(
        "SELECT * FROM reminder WHERE deleted=0 AND (fired_ts IS NULL "
        "OR repeat!='') ORDER BY at").fetchall()


DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]


def valid_repeat(s):
    """Normalize a recurrence to 'daily' or an ordered weekday list
    ('tue', 'mon,wed,fri'), else '' (one-shot). Lenient with the parser's
    phrasing: full day names, ranges ('mon-fri'), weekday(s)/weekend(s)."""
    days = set()
    for t in re.split(r"[,\s/&+]+", (s or "").strip().lower()):
        if not t:
            continue
        if t in ("daily", "everyday", "day", "days", "all"):
            return "daily"
        if t in ("weekday", "weekdays"):
            days |= set(range(5))
            continue
        if t in ("weekend", "weekends"):
            days |= {5, 6}
            continue
        span = [next((i for i, n in enumerate(DAYS) if p.startswith(n)), None)
                for p in t.split("-")]
        if None in span or len(span) > 2:
            continue
        a, b = span[0], span[-1]
        days |= set(range(a, b + 1) if a <= b else
                    list(range(a, 7)) + list(range(0, b + 1)))
    if len(days) == 7:
        return "daily"
    return ",".join(DAYS[i] for i in sorted(days))


def repeat_days(repeat):
    return list(range(7)) if repeat == "daily" else \
        [DAYS.index(d) for d in repeat.split(",")]


def fmt_repeat(repeat):
    ds = repeat_days(repeat)
    if len(ds) == 7:
        return "every day"
    labels = [DAYS[i].capitalize() for i in ds]
    if len(ds) > 2 and ds == list(range(ds[0], ds[-1] + 1)):
        return f"every {labels[0]}–{labels[-1]}"
    return "every " + (" & ".join(labels) if len(labels) <= 2 else ", ".join(labels))


def next_at(repeat, hhmm, after):
    """First 'yyyy-mm-dd HH:MM' strictly after datetime `after` that lands
    on a repeat day at that clock time."""
    ds = set(repeat_days(repeat))
    floor = after.strftime("%Y-%m-%d %H:%M")
    day = after.date()
    for _ in range(8):
        cand = f"{day.isoformat()} {hhmm}"
        if day.weekday() in ds and cand > floor:
            return cand
        day += timedelta(days=1)


def fmt_reminder(r, with_date=True):
    dt = datetime.strptime(r["at"], "%Y-%m-%d %H:%M")
    who = f" — {r['assignee']}" if r["assignee"] else ""
    if r["repeat"]:
        return f"{fmt_repeat(r['repeat'])} {fmt_clock(dt)} - {r['text']}{who}"
    when = f"{dt.strftime('%a %b %-d')} {fmt_clock(dt)}" if with_date else fmt_clock(dt)
    return f"{when} - {r['text']}{who}"


def valid_at(s):
    """Normalize a 'yyyy-mm-dd HH:MM' (or ISO T) local timestamp, else ''."""
    try:
        return datetime.strptime((s or "").strip().replace("T", " ")[:16],
                                 "%Y-%m-%d %H:%M").strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return ""


def do_remind_add(db, act, sender):
    text = (act.get("text") or "").strip()[:120]
    at = valid_at(act.get("at"))
    repeat = valid_repeat(act.get("repeat"))
    if not text or not at:
        return "Remind who to do what, when? ('remind me thursday at 9 to call the vet')"
    if repeat:
        # The parser's `at` is only trusted for its clock time; the date is
        # recomputed so the first ping is the next matching day.
        at = next_at(repeat, at[11:], datetime.now(TZ))
    elif at < datetime.now(TZ).strftime("%Y-%m-%d %H:%M"):
        return f"{at} is already in the past — when should I actually ping?"
    who = valid_assignee(act.get("assignee"))
    db.execute("INSERT INTO reminder(text,at,repeat,assignee,created_by,created_ts)"
               " VALUES(?,?,?,?,?,?)", (text, at, repeat, who, sender, int(time.time())))
    db.commit()
    r = db.execute("SELECT * FROM reminder ORDER BY id DESC LIMIT 1").fetchone()
    queue_cal(db, "create", rem_uid(r["id"]),
              f"⏰ {text}{' — ' + who if who else ''}", at, sender)
    tail = f" (next: {r['at'][:10]})" if repeat else ""
    return f"⏰ will do — {fmt_reminder(r)}{tail}"


def mark_fired(db, r, now):
    """Retire a just-fired one-shot; roll a recurring reminder to its next
    occurrence (fired_ts = last fired) and move its calendar mirror along.
    Rolling from `now` rather than from `at` means a bot that was down for
    days fires one late catch-up ping, not a backlog."""
    if r["repeat"]:
        nxt = next_at(r["repeat"], r["at"][11:], now)
        db.execute("UPDATE reminder SET fired_ts=?, at=? WHERE id=?",
                   (int(time.time()), nxt, r["id"]))
        db.commit()
        queue_cal(db, "delete", rem_uid(r["id"]))
        queue_cal(db, "create", rem_uid(r["id"]),
                  f"⏰ {r['text']}{' — ' + r['assignee'] if r['assignee'] else ''}",
                  nxt, r["created_by"])
    else:
        db.execute("UPDATE reminder SET fired_ts=? WHERE id=?",
                   (int(time.time()), r["id"]))
        db.commit()


OUTBOX_FLAG = os.path.join(os.path.dirname(DB_PATH), "outbox.flag")


def queue_cal(db, op, uid, summary="", start="", sender=""):
    """Queue a calendar create/delete and poke the credentialed sync unit
    (a systemd path unit watches the flag file); it hits Migadu within
    seconds. Tasks and reminders mirror onto the calendar through here
    with deterministic uids, so moving/finishing them updates the event.
    A calendar-less database (the scratchpad) mirrors nothing.
    """
    if not db.cal:
        return
    db.execute("INSERT INTO cal_outbox(op,uid,summary,start,created_by,created_ts)"
               " VALUES(?,?,?,?,?,?)", (op, uid, summary, start, sender, int(time.time())))
    db.commit()
    try:
        with open(OUTBOX_FLAG, "w") as f:
            f.write(str(time.time()))
    except OSError:
        log.exception("outbox flag write failed")  # 30-min timer still delivers


def task_uid(task_id):
    # Retained only so the one-time merge can retire the old task mirrors.
    return f"remy-task-{task_id}@remy.local"


def item_uid(item_id):
    return f"remy-item-{item_id}@remy.local"


def rem_uid(rem_id):
    return f"remy-rem-{rem_id}@remy.local"


def sync_item_event(db, item_id):
    """Make the calendar mirror match the item row: delete the old event,
    re-create if the item is open and dated (all-day on the due day). Only
    dated items ever reach the calendar."""
    r = db.execute("SELECT * FROM item WHERE id=?", (item_id,)).fetchone()
    queue_cal(db, "delete", item_uid(item_id))
    if r and not r["deleted"] and r["done_ts"] is None and r["due"]:
        queue_cal(db, "create", item_uid(item_id),
                  f"☐ {r['name']}{fmt_who(r)}", r["due"], r["added_by"])


def do_cal_add(db, act, sender):
    title = (act.get("text") or "").strip()[:120]
    at = valid_at(act.get("at")) or valid_date((act.get("at") or "").strip()[:10])
    if not title or not at:
        return "Put what on the calendar, when? ('dentist on the calendar tuesday at 3')"
    row_ts = int(time.time())
    db.execute("INSERT INTO cal_outbox(summary,start,created_by,created_ts)"
               " VALUES(?,?,?,?)", (title, at, sender, row_ts))
    db.commit()
    r = db.execute("SELECT id FROM cal_outbox ORDER BY id DESC LIMIT 1").fetchone()
    db.execute("UPDATE cal_outbox SET uid=? WHERE id=?",
               (f"remy-chat-{r['id']}-{row_ts}@remy.local", r["id"]))
    db.commit()
    try:
        with open(OUTBOX_FLAG, "w") as f:
            f.write(str(time.time()))
    except OSError:
        log.exception("outbox flag write failed")
    d = date.fromisoformat(at[:10])
    when = d.strftime("%a %b %-d") + (f" {at[11:]}" if len(at) > 10 else " (all day)")
    return f"🗓 {title} — {when}, putting it on the calendar now"


def do_remind_cancel(db, act):
    # Matched by words, since no ids are visible; ambiguity asks.
    rows = pending_reminders(db)
    txt = (act.get("text") or "").strip().lower()
    if txt:
        rows = [r for r in rows if txt in r["text"].lower()]
    if not rows:
        return "No matching reminder to cancel."
    if len(rows) > 1 and not txt:
        return "Which reminder? Name part of it ('cancel the vet reminder')."
    r = rows[0]
    db.execute("UPDATE reminder SET deleted=1 WHERE id=?", (r["id"],))
    db.commit()
    queue_cal(db, "delete", rem_uid(r["id"]))
    return f"🗑 cancelled {fmt_reminder(r)}"


def do_remind_show(db, act=None):
    rows = pending_reminders(db)
    scope = (act or {}).get("scope") or "all"
    now = today()
    with_date = True
    if scope == "today":
        rows = [r for r in rows if r["at"][:10] == now.isoformat()]
        head, with_date = "Reminders today:", False  # all today -> time is enough
    elif scope == "week":
        end = (now + timedelta(days=6 - now.weekday())).isoformat()
        rows = [r for r in rows if r["at"][:10] <= end]
        head = "Reminders this week:"
    else:
        head = "Reminders set:"
    return head + "\n" + ("\n".join("⏰ " + fmt_reminder(r, with_date) for r in rows) or "(none)")


def renumber(db, list_name):
    """Compact a list's OPEN items to 1..N by id so displayed numbers stay
    gap-free; retired rows get 0. Run after any change to the list."""
    for i, row in enumerate(db.execute(
            "SELECT id FROM item WHERE list_name=? AND deleted=0 AND done_ts IS NULL "
            "ORDER BY id", (list_name,)).fetchall(), 1):
        db.execute("UPDATE item SET seq=? WHERE id=?", (i, row["id"]))
    db.execute("UPDATE item SET seq=0 WHERE list_name=? AND (deleted=1 OR done_ts IS NOT NULL)",
               (list_name,))
    db.commit()


def get_open(db, act):
    """Resolve an item the way people refer to it: its list plus the number
    shown next to it. Open items only (numbers only ever label open items)."""
    ln = (act.get("list_name") or "").strip().lower()
    seq = act.get("item_id") or 0
    if not ln or not seq:
        return None
    return db.execute("SELECT * FROM item WHERE list_name=? AND seq=? AND deleted=0 "
                      "AND done_ts IS NULL", (ln, seq)).fetchone()


NEED_REF = ("Which item? Say its list and number (e.g. 'done 2 on shopping') "
            "or just name it ('got the milk').")


def do_item_add(db, act, sender):
    names = [n.strip()[:80] for n in act.get("items", []) if n.strip()]
    ln = (act.get("list_name") or "shopping").strip().lower()[:30]
    section = (act.get("section") or "").strip().lower()[:30]
    due = valid_date(act.get("due", ""))
    who = valid_assignee(act.get("assignee"))
    if not names:
        # "make a packing list": a list exists once something is on it, so
        # just teach the phrasing.
        return f"👍 '{ln}' it is — put things on it like 'add milk to {ln}'."
    now_ts = int(time.time())
    ids = []
    for n in names:
        db.execute("INSERT INTO item(list_name,name,due,assignee,section,added_by,added_ts)"
                   " VALUES(?,?,?,?,?,?,?)", (ln, n, due, who, section, sender, now_ts))
        ids.append(db.execute("SELECT last_insert_rowid() r").fetchone()["r"])
    db.commit()
    renumber(db, ln)
    if due:
        for i in ids:
            sync_item_event(db, i)
    n_open = db.execute("SELECT COUNT(*) c FROM item WHERE list_name=? AND deleted=0 "
                        "AND done_ts IS NULL", (ln,)).fetchone()["c"]
    tail = fmt_due(due) + (f" ({who})" if who else "")
    return f"✓ {', '.join(names)} → {ln}{tail} ({n_open} on the list)"


def do_item_done(db, act, sender):
    r = get_open(db, act)
    if not r:
        return NEED_REF
    db.execute("UPDATE item SET done_ts=?, done_by=? WHERE id=?",
               (int(time.time()), sender, r["id"]))
    db.commit()
    renumber(db, r["list_name"])
    if r["due"]:
        sync_item_event(db, r["id"])
    return f"✔ {r['name']} checked off {r['list_name']}"


def do_item_edit(db, act):
    r = get_open(db, act)
    if not r:
        return NEED_REF
    changes, params = [], []
    if act.get("new_name"):
        changes.append("name=?"); params.append(act["new_name"].strip()[:80])
    if act.get("new_due"):
        # get_open only returns open items, so done_ts is already NULL here.
        changes.append("due=?"); params.append(valid_date(act["new_due"]))
    if act.get("new_assignee"):
        changes.append("assignee=?"); params.append(valid_assignee(act["new_assignee"]))
    if not changes:
        return "Nothing to change that I understood."
    db.execute(f"UPDATE item SET {','.join(changes)} WHERE id=?", (*params, r["id"]))
    db.commit()
    renumber(db, r["list_name"])
    sync_item_event(db, r["id"])
    return "✏️ " + fmt_item(db.execute("SELECT * FROM item WHERE id=?", (r["id"],)).fetchone())


def do_item_remove(db, act):
    r = get_open(db, act)
    if not r:
        return NEED_REF
    db.execute("UPDATE item SET deleted=1 WHERE id=?", (r["id"],))
    db.commit()
    renumber(db, r["list_name"])
    if r["due"]:
        sync_item_event(db, r["id"])
    return f"🗑 removed {r['name']} from {r['list_name']} (say 'restore the {r['name']}' to undo)"


def do_item_restore(db, act):
    # Removed items no longer carry a live number, so bring one back by name
    # (most recent match), optionally scoped to a list.
    name = (act.get("new_name") or "").strip().lower()
    ln = (act.get("list_name") or "").strip().lower()
    q, args = "SELECT * FROM item WHERE deleted=1", []
    if ln:
        q += " AND list_name=?"; args.append(ln)
    if name:
        q += " AND lower(name) LIKE ?"; args.append(f"%{name}%")
    q += " ORDER BY id DESC LIMIT 1"
    r = db.execute(q, tuple(args)).fetchone()
    if not r:
        return "Nothing removed to bring back."
    db.execute("UPDATE item SET deleted=0 WHERE id=?", (r["id"],))
    db.commit()
    renumber(db, r["list_name"])
    r = db.execute("SELECT * FROM item WHERE id=?", (r["id"],)).fetchone()
    if r["due"]:
        sync_item_event(db, r["id"])
    return "↩️ restored " + fmt_item(r)


def do_list_show(db, act):
    ln = (act.get("list_name") or "").strip().lower()
    if not ln:
        return do_lists_show(db)
    rows = open_items(db, ln)
    if not rows:
        return f"'{ln}' is empty."
    lines, last_sec = [f"{ln}:"], None
    for r in rows:
        if r["section"] != last_sec:
            if r["section"]:
                lines.append(f"  [{r['section']}]")
            last_sec = r["section"]
        lines.append(f"  {fmt_item(r)}")
    out = "\n".join(lines)
    # The to-dos list doubles as "my plate" — fold in the week's calendar and
    # reminders so asking for it is never missing the schedule.
    if ln == "to-dos":
        for extra in (cal_peek(db) if db.cal else "", rem_peek(db, "week")):
            if extra:
                out += "\n\n" + extra
    return out


def do_lists_show(db):
    rows = db.execute(
        "SELECT list_name, COUNT(*) c FROM item WHERE deleted=0 AND done_ts IS NULL "
        "GROUP BY list_name ORDER BY list_name").fetchall()
    if not rows:
        return "No lists yet — start one like 'add milk to shopping'."
    return "Your lists:\n" + "\n".join(f"  • {r['list_name']} ({r['c']})" for r in rows)


def do_list_rename(db, act):
    ln = (act.get("list_name") or "").strip().lower()
    new = (act.get("new_list_name") or "").strip().lower()[:30]
    if not ln or not new:
        return "Rename which list to what? ('rename hardware to garage')"
    n = db.execute("UPDATE item SET list_name=? WHERE list_name=? AND deleted=0",
                   (new, ln)).rowcount
    db.commit()
    if not n:
        return f"No open list called '{ln}'."
    renumber(db, new)  # merged into a possibly-existing list — recompact it
    return f"✏️ '{ln}' → '{new}' ({n} item{'s' if n != 1 else ''})"


def do_list_clear(db, act):
    ln = (act.get("list_name") or "").strip().lower()
    if not ln:
        return "Clear which list?"
    n = db.execute("UPDATE item SET deleted=1 WHERE list_name=? AND deleted=0",
                   (ln,)).rowcount
    db.commit()
    renumber(db, ln)
    return f"🧹 cleared {ln} ({n} item{'s' if n != 1 else ''}; restorable from history)"


def do_todos_show(db, act):
    scope = act.get("scope") or "all"
    now = today()
    if scope == "done":
        rows = db.execute(
            "SELECT * FROM item WHERE list_name='to-dos' AND deleted=0 "
            "AND done_ts IS NOT NULL ORDER BY done_ts DESC LIMIT 10").fetchall()
        return "Recently done:\n" + ("\n".join(
            f"✔ {r['name']} ({r['done_by']})" for r in rows) or "(nothing yet)")
    rows = open_items(db, "to-dos")
    who = valid_assignee(act.get("assignee"))
    if who:
        # "what do I have" means mine PLUS the household's unassigned ones —
        # the whole point is what I could go do, not only what carries my name.
        rows = [r for r in rows if r["assignee"] in (who, "")]
    # Undated to-dos are standing tasks — they belong in every view except the
    # strictly date-bounded "overdue" one. Only dated items get windowed.
    if scope == "today":
        rows = [r for r in rows if not r["due"] or r["due"] <= now.isoformat()]
        head = "To-dos" + (f" — {who}" if who else "") + ":"
    elif scope == "overdue":
        rows = [r for r in rows if r["due"] and r["due"] < now.isoformat()]
        head = "Overdue:"
    elif scope == "week":
        end = (now + timedelta(days=6 - now.weekday())).isoformat()
        rows = [r for r in rows if not r["due"] or r["due"] <= end]
        head = "To-dos" + (f" — {who}" if who else "") + ":"
    else:
        head = "To-dos" + (f" — {who}" if who else "") + ":"
    out = head + "\n" + ("\n".join(fmt_item(r) for r in rows) or "(nothing!)")
    if scope in ("", "all", "today", "week"):
        rem_scope = scope if scope in ("today", "week") else "all"
        for extra in (cal_peek(db) if db.cal else "", rem_peek(db, rem_scope)):
            if extra:
                out += "\n\n" + extra
    return out


def do_log_add(db, act, sender):
    if not db.cal:
        return "The daily log lives in the Household room — add to it there."
    txt = (act.get("text") or "").strip()[:400]
    if not txt:
        return "Add what to the log? ('add to log: Julia had her baby today')"
    db.execute("INSERT INTO log_note(day,text,added_by,added_ts) VALUES(?,?,?,?)",
               (today().isoformat(), txt, sender, int(time.time())))
    db.commit()
    return f"📝 added to today's log — {txt}"


def week_section(db, start, title="📅 Week ahead:"):
    """From `start` through that week's Sunday (weeks run Monday–Sunday):
    calendar events by day, then the week's dated to-dos as their own list."""
    end = start + timedelta(days=6 - start.weekday())
    todos = [r for r in dated_open(db)
             if start.isoformat() <= r["due"] <= end.isoformat()]
    events, _ = calendar_events(start, end)
    if not todos and not events:
        return f"{title} clear so far."
    by_day = {}
    for ev in events:
        by_day.setdefault(ev["start"][:10], []).append("◦ " + fmt_event(ev))
    lines = [title]
    for d in sorted(by_day):
        lines.append(date.fromisoformat(d).strftime("%A %b %-d") + ":")
        lines += ["  " + s for s in by_day[d]]
    if todos:
        lines.append("To-dos due:")
        lines += [f"  • {r['name']}{fmt_who(r)}{fmt_due(r['due'])}" for r in todos]
    return "\n".join(lines)


def cal_peek(db):
    """Today through this week's Sunday, calendar events only — folded into the
    to-do view so "show me my tasks" always carries the schedule too. '' when
    there's nothing (or no calendar)."""
    now = today()
    end = now + timedelta(days=6 - now.weekday())
    events, _ = calendar_events(now, end)
    if not events:
        return ""
    by_day = {}
    for ev in events:
        by_day.setdefault(ev["start"][:10], []).append("  ◦ " + fmt_event(ev))
    lines = ["📅 Calendar this week:"]
    for d in sorted(by_day):
        lines.append(date.fromisoformat(d).strftime("%A %b %-d") + ":")
        lines += by_day[d]
    return "\n".join(lines)


def rem_peek(db, scope="week"):
    """Pending reminders for a scope, as a section for the to-do view. today =
    time only (all same day); week = through Sunday, dated; all = everything."""
    rows = pending_reminders(db)
    now = today()
    with_date = True
    if scope == "today":
        rows = [r for r in rows if r["at"][:10] == now.isoformat()]
        with_date = False
    elif scope == "week":
        end = (now + timedelta(days=6 - now.weekday())).isoformat()
        rows = [r for r in rows if r["at"][:10] <= end]
    if not rows:
        return ""
    return "⏰ Reminders:\n" + "\n".join("  " + fmt_reminder(r, with_date) for r in rows)


def morning_post(db):
    now = today()
    lines = [f"☀️ {now.strftime('%A, %B %-d')}"]
    dated = dated_open(db)
    overdue = [r for r in dated if r["due"] < now.isoformat()]
    due_today = [r for r in dated if r["due"] == now.isoformat()]
    if overdue:
        lines.append("Overdue:")
        lines += [f"  • {r['name']}{fmt_who(r)}{fmt_due(r['due'])}" for r in overdue]
    if due_today:
        lines.append("Today:")
        lines += [f"  • {r['name']}{fmt_who(r)}" for r in due_today]
    # Undated open to-dos would otherwise never surface in the day post.
    undated = [r for r in open_items(db, "to-dos") if not r["due"]]
    if undated:
        lines.append("📋 To-dos:")
        lines += [f"  {r['seq']}. {r['name']}{fmt_who(r)}" for r in undated]
    rems = [r for r in pending_reminders(db) if r["at"][:10] == now.isoformat()]
    if rems:
        lines.append("Reminders today:")
        lines += [f"  ⏰ {r['at'][11:]} {r['text']}{fmt_who(r)}" for r in rems]
    events, note = calendar_events(now, now)
    if events:
        lines.append("Calendar:")
        lines += ["  ◦ " + fmt_event(ev) for ev in events]
    if note:
        lines.append(note)
    if len(lines) == 1:
        lines.append("Nothing scheduled — enjoy the day.")
    if now.weekday() < 6:  # the rest of the week, through Sunday
        lines.append("")
        lines.append(week_section(db, now + timedelta(days=1),
                                  "📅 Rest of the week:"))
    return "\n".join(lines)


def evening_post(db):
    now = today()
    day_start = int(datetime.combine(now, datetime.min.time(), TZ).timestamp())
    lines = [f"🌙 Evening report — {now.strftime('%A')}"]
    done = db.execute(
        "SELECT * FROM item WHERE deleted=0 AND done_ts>=? ORDER BY done_ts",
        (day_start,)).fetchall()
    if done:
        lines.append("Done today:")
        lines += [f"  ✔ {r['name']} ({r['done_by']})" for r in done]
    missed = [r for r in dated_open(db) if r["due"] <= now.isoformat()]
    if missed:
        lines.append("Last call:")
        lines += [f"  • {r['name']}{fmt_who(r)}{fmt_due(r['due'])}" for r in missed]
    undated = [r for r in open_items(db, "to-dos") if not r["due"]]
    if undated:
        lines.append("📋 Still on the list:")
        lines += [f"  {r['seq']}. {r['name']}{fmt_who(r)}" for r in undated]
    tomorrow = now + timedelta(days=1)
    due_tmrw = [r for r in dated_open(db) if r["due"] == tomorrow.isoformat()]
    events, _ = calendar_events(tomorrow, tomorrow)
    if due_tmrw or events:
        lines.append("Tomorrow:")
        lines += [f"  • {r['name']}{fmt_who(r)}" for r in due_tmrw]
        lines += ["  ◦ " + fmt_event(ev) for ev in events]
    if len(lines) == 1:
        lines.append("Quiet day — nothing logged, nothing due.")
    if now.weekday() == 6:  # Sunday: look at the week
        lines.append("")
        lines.append(week_section(db, tomorrow))
    return "\n".join(lines)



def fmt_clock(dt):
    """A datetime -> a friendly '10am' / '2:30pm'."""
    ap = dt.strftime("%p").lower()
    return f"{dt.strftime('%-I')}{ap}" if dt.minute == 0 else f"{dt.strftime('%-I:%M')}{ap}"


def build_day_log(db, day):
    """The day's raw material for the log: (itinerary_lines, done, notes).

    itinerary = timed calendar events + reminders that fired, in time order;
    done = items checked off that day; notes = what people dropped in with
    'add to log'. All deterministic — no model involved here.
    """
    d_iso = day.isoformat()
    day_start = int(datetime.combine(day, datetime.min.time(), TZ).timestamp())
    day_end = day_start + 86400
    entries = []  # (sortkey, text)
    events, _ = calendar_events(day, day)
    for ev in events:
        s = ev["start"]
        summ = ev.get("summary", "(untitled)")
        if len(s) > 10:
            t = datetime.fromisoformat(s).astimezone(TZ)
            entries.append((t.strftime("%H:%M"), f"{fmt_clock(t)} — {summ}"))
        else:
            entries.append(("zz", f"all day — {summ}"))
    for r in db.execute(
            "SELECT * FROM reminder WHERE deleted=0 AND fired_ts>=? AND fired_ts<? ORDER BY at",
            (day_start, day_end)).fetchall():
        hhmm = r["at"][11:]
        clock = fmt_clock(datetime.strptime(hhmm, "%H:%M")) if hhmm else "reminder"
        entries.append((hhmm or "zz", f"{clock} — {r['text']}"))
    entries.sort(key=lambda x: x[0])
    done = [r["name"] for r in db.execute(
        "SELECT * FROM item WHERE deleted=0 AND done_ts>=? AND done_ts<? ORDER BY done_ts",
        (day_start, day_end)).fetchall()]
    notes = [r["text"] for r in db.execute(
        "SELECT text FROM log_note WHERE day=? AND deleted=0 ORDER BY id", (d_iso,)).fetchall()]
    return [e[1] for e in entries], done, notes


LOG_SYS = """You are writing one day's entry in a family's shared daily log — a
warm, human record of the day. You get: the day's itinerary (timed things, in
order), what got done, and freeform notes people dropped in chat. Produce
GitHub-flavored markdown for the body only (a date heading is added for you).
Rules, followed exactly:
- Render the itinerary as a bulleted list, in the given order and wording
  ("- 10am — meet with Julia").
- If a note clearly refers to one itinerary line (same person or event), attach
  it as an indented sub-bullet under that line ("  - she just had her baby").
  Notes that don't match any line go under a final "- also:" bullet.
- If the notes convey the day's overall mood or a noteworthy moment, end with ONE
  italic sentence capturing it. If they don't, add nothing.
- Invent NOTHING — use only the facts given. No date heading.
Output only the markdown body."""


def build_day_markdown(db, day):
    timed, done, notes = build_day_log(db, day)
    header = f"## {day.strftime('%A, %B %-d, %Y')}"
    if not timed and not done and not notes:
        return f"{header}\n\nQuiet one — nothing on the books.\n"
    scaffold = [f"- {t}" for t in timed] + [f"- did: {d}" for d in done]
    plain = header + "\n\n" + "\n".join(scaffold) + "\n"
    if not notes:
        return plain
    # Notes are what make a day read like a day — hand the scaffold + notes to
    # the local model to weave them in and add a closing line. Fall back to the
    # plain scaffold (notes listed) if the model is unavailable or misbehaves.
    payload = ("Itinerary (in order):\n" + ("\n".join(f"- {t}" for t in timed) or "- (nothing timed)")
               + "\n\nGot done:\n" + ("\n".join(f"- {d}" for d in done) or "- (nothing logged)")
               + "\n\nNotes from chat:\n" + "\n".join(f"- {n}" for n in notes))
    try:
        out = llm_text(LOG_SYS, payload).strip()
        if out:
            return header + "\n\n" + out + "\n"
    except Exception:
        log.exception("log compose failed; using scaffold")
    return plain + "Notes:\n" + "\n".join(f"- {n}" for n in notes) + "\n"


def write_log(db, day):
    """Append the day's entry to the log file and poke the vault mirror.

    Idempotent per day: the scheduler stamps completion only after this
    returns, so a crash in between would retry — the header check turns
    that retry into a no-op instead of a duplicate day.
    """
    md = build_day_markdown(db, day)
    header = md.split("\n", 1)[0]
    try:
        with open(LOG_PATH) as f:
            if header in f.read():
                return
    except OSError:
        pass
    new_file = not os.path.exists(LOG_PATH) or os.path.getsize(LOG_PATH) == 0
    with open(LOG_PATH, "a") as f:
        if new_file:
            f.write("# Family log\n\n")
        else:
            f.write("\n")
        f.write(md)
    try:
        os.chmod(LOG_PATH, 0o644)  # the mirror unit (a different user) reads it
    except OSError:
        pass
    # The vault mirror's path unit watches log.md itself, so the append above
    # is the trigger.


HOME_HELP = """I keep the family organized around three things — lists, the
calendar, and reminders — plus a daily log. Examples:
• add milk and eggs to shopping / got the milk / show the shopping list
• make a packing list / what lists do we have? / rename hardware to garage
• we need to renew the registration by friday / I need dylan to call the plumber thursday
• what do I still have to do? / what's on gab's plate this week? / got the milk / done 2 on shopping
• remind me thursday at 9 to defrost the chicken / what reminders are set?
• remind us every tuesday at 10 to put the bins out — repeats until you cancel it
• put the dentist on the calendar tuesday at 3 — goes straight to Migadu
• add to log: Julia had her baby today — I write the day's log each night
• what's on today? / this week? — morning/evening summaries post at 7:00 and 19:00
If I'm not sure which list something belongs on, I'll ask."""

SCRATCH_HELP = """Your scratchpad — notes, reminders, to-dos, quick lists. Examples:
• note: the gate code is 4482 / show the notes list
• remind me at 5 to leave / remind me every weekday at 10 to check in / what reminders are set?
• renew the passport by friday / what do I still have to do? / done 3 on to-dos
• add batteries to hardware / what lists do we have?
Summaries show the family calendar, but it's read-only from here —
add events in the Household room. No scheduled posts; ask when you
want a summary."""



class Bot:
    def __init__(self):
        self.hdb = home_db()
        self.sdb = home_db(SCRATCH_DB_PATH, cal=False) if SCRATCH_USERS else None
        self.client = AsyncClient(HS_URL, USER_ID)
        self.home_room = None
        self.scratch_room = None

    async def send(self, room_id, text, notify=False, mention=None):
        # Scheduled posts are m.text (they should ping phones); command
        # replies are m.notice (quieter, and other bots ignore notices).
        # mention: a FAMILY localpart for a personal ping, or "room" for
        # everyone. A real mention is two things: m.mentions (the push
        # signal) AND a matrix.to pill in formatted_body (what clients
        # render/highlight) — plain "@name" text does neither.
        content = {"msgtype": "m.text" if notify else "m.notice", "body": text}
        if mention == "room":
            content["m.mentions"] = {"room": True}
        elif mention:
            domain = self.client.user_id.split(":", 1)[1]
            user_id = f"@{mention}:{domain}"
            content["m.mentions"] = {"user_ids": [user_id]}
            escaped = html.escape(text).replace("\n", "<br/>")
            pill = f'<a href="https://matrix.to/#/{user_id}">@{mention}</a>'
            content["format"] = "org.matrix.custom.html"
            content["formatted_body"] = escaped.replace(
                html.escape(f"@{mention}"), pill, 1)
        resp = await self.client.room_send(room_id, "m.room.message", content)
        # nio reports Matrix-level failures (4xx/5xx) as error OBJECTS, not
        # exceptions — without this check a failed send would still count as
        # delivered wherever callers stamp after send.
        if not getattr(resp, "event_id", None):
            raise RuntimeError(f"send to {room_id} failed: {resp}")


    async def on_message(self, room, event):
        if event.sender == self.client.user_id:
            return
        if room.room_id == self.home_room:
            handler = partial(self.handle_home, self.hdb)
        elif self.scratch_room and room.room_id == self.scratch_room:
            handler = partial(self.handle_home, self.sdb)
        else:
            return
        # One processed-table (the household db) covers both rooms.
        if self.hdb.execute("SELECT 1 FROM processed WHERE event_id=?",
                            (event.event_id,)).fetchone():
            return
        # Replay policy: catch up on messages missed while down (up to 7
        # days), but NEVER before this database first existed — a fresh DB
        # must not chew either room's prior history into duplicate entries.
        first_start = int(meta_get(self.hdb, "first_start_ms") or 0)
        if event.server_timestamp < max(first_start, START_MS - 7 * 86400 * 1000):
            return
        text = event.body.strip()
        if not text:
            return
        # Mark 'seen' before handling, 'done' after: still deliberate
        # at-most-once (replaying a half-applied mutation could double-file
        # it), but a crash mid-handling is no longer a silent loss — rows
        # stuck at 'seen' are reported to the room on the next start
        # (report_interrupted).
        self.hdb.execute(
            "INSERT INTO processed(event_id,ts,status,body,room) VALUES(?,?,?,?,?)",
            (event.event_id, int(time.time()), "seen", text[:120], room.room_id))
        self.hdb.commit()
        sender = event.sender.split(":")[0].lstrip("@")
        try:
            await handler(room.room_id, sender, event, text)
        except Exception:
            # The user saw a reply (or the send itself is what died) —
            # either way it was handled as far as it will ever be.
            log.exception("action failed")
            try:
                await self.send(room.room_id, "(something broke doing that — it's logged)")
            except Exception:
                log.exception("error reply failed")
        self.hdb.execute("UPDATE processed SET status='done' WHERE event_id=?",
                         (event.event_id,))
        self.hdb.commit()

    async def handle_home(self, db, room_id, sender, event, text):
        try:
            acts = await asyncio.to_thread(home_parse, db, sender, text)
        except Exception:
            log.exception("parse failed")
            await self.send(room_id, "(I choked parsing that — try again?)")
            return
        log.info("%s %s: %r -> %s", "home" if db is self.hdb else "scratch",
                 sender, text, [a.get("intent") for a in acts])
        MUTATORS = ("item_add", "item_done", "item_edit", "item_remove",
                    "item_restore", "list_rename", "list_clear", "cal_add",
                    "remind_add", "remind_cancel", "log_add")
        replies, mutated = [], []
        for act in acts[:8]:  # runaway-parse backstop
            intent = act.get("intent")
            handlers = {
                "item_add": lambda a=act: do_item_add(db, a, sender),
                "item_done": lambda a=act: do_item_done(db, a, sender),
                "item_edit": lambda a=act: do_item_edit(db, a),
                "item_remove": lambda a=act: do_item_remove(db, a),
                "item_restore": lambda a=act: do_item_restore(db, a),
                "list_show": lambda a=act: do_list_show(db, a),
                "lists_show": lambda: do_lists_show(db),
                "list_rename": lambda a=act: do_list_rename(db, a),
                "list_clear": lambda a=act: do_list_clear(db, a),
                "todos_show": lambda a=act: do_todos_show(db, a),
                "cal_add": lambda a=act: (
                    do_cal_add(db, a, sender) if db.cal else
                    "(the calendar is read-only here — add events in the Household room)"),
                "remind_add": lambda a=act: do_remind_add(db, a, sender),
                "remind_cancel": lambda a=act: do_remind_cancel(db, a),
                "remind_show": lambda a=act: do_remind_show(db, a),
                "log_add": lambda a=act: do_log_add(db, a, sender),
            }
            if intent in handlers:
                replies.append(handlers[intent]())
            elif intent == "post_now":
                kind = act.get("kind") or "morning"
                make = {"week": lambda d: week_section(d, today()),
                        "evening": evening_post}.get(kind, morning_post)
                replies.append(make(db))
            elif intent == "help":
                replies.append(HOME_HELP if db.cal else SCRATCH_HELP)
            elif intent in ("ask", "other") and act.get("reply"):
                replies.append(act["reply"][:400])
            if intent in MUTATORS:
                mutated.append(intent)
        if replies:
            await self.send(room_id, "\n".join(replies))
        if mutated:
            db_path = DB_PATH if db is self.hdb else SCRATCH_DB_PATH
            await asyncio.to_thread(git_snapshot, db, db_path,
                                    f"{'+'.join(mutated)} by {sender}: {text[:60]}")


    async def scheduler(self):
        """All timed posts, one minute-tick loop.

        Each post is stamped per-day in meta after a successful send, so a
        restart or send failure after its time still posts (late), and a
        downed bot never back-fills yesterday's posts. At-least-once: a
        crash in the moment between send and stamp can duplicate a post —
        the right trade for family announcements.

        One bad tick (a locked database, a hiccuping disk) must not kill
        the loop: reminders dying while sync lives on is the worst failure
        mode, because nobody notices. The catch-all keeps the loop alive;
        run() takes the whole process down if the loop itself ever exits.
        """
        while True:
            await asyncio.sleep(60)
            try:
                await self.tick()
            except Exception:
                log.exception("scheduler tick failed")

    async def tick(self):
        now = datetime.now(TZ)
        hhmm = now.strftime("%H:%M")
        day = now.date().isoformat()
        # Household: morning plan + evening report. The day-stamp is
        # committed only after a successful send (like the reminder loop
        # below), so a transient homeserver failure retries on the next
        # tick instead of silently skipping the day.
        for key, at, make in (("morning", MORNING, morning_post),
                              ("evening", EVENING, evening_post)):
            if hhmm >= at and meta_get(self.hdb, f"last_{key}") != day:
                try:
                    await self.send(self.home_room, make(self.hdb), notify=True)
                    meta_set(self.hdb, f"last_{key}", day)
                except Exception:
                    log.exception("%s post failed", key)
        # The family log: composed once, late, for the day that's ending.
        # Household only (the scratchpad has no scheduled writes).
        # Stamp after the write for the same retry-on-failure reason;
        # write_log itself skips a day already in the file, so the
        # crash-between-write-and-stamp window can't duplicate an entry.
        if hhmm >= LOG_TIME and meta_get(self.hdb, "last_log") != day:
            try:
                await asyncio.to_thread(write_log, self.hdb, now.date())
                meta_set(self.hdb, "last_log", day)
            except Exception:
                log.exception("log write failed")
        # Reminders due now (or missed while down — fired late, once,
        # flagged with the time they were meant for). Household and
        # scratchpad each ping their own room.
        due_now = f"{day} {hhmm}"
        rooms = [(self.hdb, self.home_room)]
        if self.sdb and self.scratch_room:
            rooms.append((self.sdb, self.scratch_room))
        for db, room in rooms:
            for r in pending_reminders(db):
                if r["at"] > due_now:
                    break  # sorted by at
                late = r["at"] < (now - timedelta(minutes=2)).strftime("%Y-%m-%d %H:%M")
                msg = (f"⏰ {'@' + r['assignee'] + ': ' if r['assignee'] else ''}{r['text']}"
                       f"{' (meant for ' + r['at'] + ')' if late else ''}")
                try:
                    # @tag only an explicitly-named person; an unassigned
                    # reminder still notifies (m.text) but pings no one.
                    await self.send(room, msg, notify=True,
                                    mention=r["assignee"] or None)
                    mark_fired(db, r, now)
                except Exception:
                    log.exception("reminder %s failed", r["id"])


    async def ensure_rooms(self):
        """First start: create the Household (and scratchpad) rooms."""
        self.home_room = meta_get(self.hdb, "room_id")
        if not self.home_room:
            resp = await self.client.room_create(
                name=ROOM_NAME,
                topic="Tasks, lists, and the day's plan — talk to me in plain language.",
                invite=INVITE_USERS,
                # The first invitee gets admin alongside the bot.
                power_level_override={
                    "users": {self.client.user_id: 100,
                              **({INVITE_USERS[0]: 100} if INVITE_USERS else {})}},
            )
            if not getattr(resp, "room_id", None):
                raise SystemExit(f"room create failed: {resp}")
            self.home_room = resp.room_id
            meta_set(self.hdb, "room_id", self.home_room)
            log.info("created room %s (%s)", ROOM_NAME, self.home_room)
        # The scratchpad: the primary user's private notes/reminders room,
        # created the same way (its id lives in the household meta table).
        self.scratch_room = meta_get(self.hdb, "scratch_room_id")
        if SCRATCH_USERS and not self.scratch_room:
            resp = await self.client.room_create(
                name=SCRATCH_ROOM_NAME,
                topic="Notes, reminders, and quick stuff — just us.",
                invite=SCRATCH_USERS,
                power_level_override={
                    "users": {self.client.user_id: 100, SCRATCH_USERS[0]: 100}},
            )
            if not getattr(resp, "room_id", None):
                raise SystemExit(f"scratchpad room create failed: {resp}")
            self.scratch_room = resp.room_id
            meta_set(self.hdb, "scratch_room_id", self.scratch_room)
            log.info("created room %s (%s)", SCRATCH_ROOM_NAME, self.scratch_room)

    async def report_interrupted(self):
        """Events stuck at 'seen' are a crash mid-handling: half-done or not
        done at all. Deliberately NOT replayed (a half-applied mutation
        could double-file) — say so in the room instead, so a dropped
        request costs a re-ask, never silence."""
        for row in self.hdb.execute(
                "SELECT * FROM processed WHERE status='seen'").fetchall():
            try:
                await self.send(row["room"] or self.home_room,
                                f'⚠️ I was interrupted handling "{row["body"][:80]}" — '
                                "double-check it took, and re-send if not.")
            except Exception:
                # Leave it 'seen'; the next start tries again.
                log.exception("interrupted-report failed for %s", row["event_id"])
                continue
            self.hdb.execute("UPDATE processed SET status='reported' WHERE event_id=?",
                             (row["event_id"],))
            self.hdb.commit()

    async def run(self):
        if not meta_get(self.hdb, "first_start_ms"):
            meta_set(self.hdb, "first_start_ms", str(START_MS))
        # Reuse the stored session when valid; else password login. A
        # token found in the DATABASE is legacy state whose value is
        # already baked into the history repo's dumps — log it out (which
        # invalidates every historical copy of it) and start fresh.
        legacy_tok = meta_get(self.hdb, "access_token")
        legacy_dev = meta_get(self.hdb, "device_id")
        tok, dev = load_session()
        if tok and dev:
            self.client.restore_login(USER_ID, dev, tok)
            whoami = await self.client.whoami()
            if getattr(whoami, "user_id", None) != USER_ID:
                tok = None
        if not (tok and dev):
            if legacy_tok and legacy_dev:
                self.client.restore_login(USER_ID, legacy_dev, legacy_tok)
                try:
                    await self.client.logout()
                except Exception:
                    log.exception("legacy session logout failed (continuing)")
            resp = await self.client.login(PASSWORD, device_name="remy")
            if not getattr(resp, "access_token", None):
                raise SystemExit(f"login failed: {resp}")
            save_session(resp.access_token, resp.device_id)
        if legacy_tok or legacy_dev:
            self.hdb.execute(
                "DELETE FROM meta WHERE k IN ('access_token','device_id')")
            self.hdb.commit()
            git_snapshot(self.hdb, DB_PATH, "scrub the matrix session from the database")
        await self.ensure_rooms()
        await self.report_interrupted()
        self.client.add_event_callback(self.on_message, RoomMessageText)
        log.info("remy up as %s (home %s, scratch %s)",
                 USER_ID, self.home_room, self.scratch_room or "-")
        # Either loop dying takes the whole process with it — systemd's
        # Restart=always brings back a complete bot, never a half-alive one
        # that syncs but forgets the reminders.
        await asyncio.gather(
            self.client.sync_forever(timeout=30000, full_state=True),
            self.scheduler())


if __name__ == "__main__":
    asyncio.run(Bot().run())
