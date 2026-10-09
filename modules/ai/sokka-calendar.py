"""Sokka's calendar: a stdio MCP server over CalDAV.

The only part of Sokka that holds the calendar login. Usage:
sokka-calendar ACCOUNTS.json, where the file is
[{"name", "url", "username", "password"}, ...]. Times are local to
SOKKA_TZ, written YYYY-MM-DD HH:MM, or YYYY-MM-DD for all-day events.
"""

import json
import os
import sys
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import caldav
from caldav.lib.error import NotFoundError
from mcp.server.fastmcp import FastMCP

ZONE = ZoneInfo(os.environ.get("SOKKA_TZ", "UTC"))
REPEATS = ("daily", "weekly", "monthly", "yearly")

with open(sys.argv[1]) as f:
    ACCOUNTS = json.load(f)

server = FastMCP("calendar")


def calendars():
    """Every calendar on every account, by the name Dylan sees."""
    found = {}
    for account in ACCOUNTS:
        client = caldav.DAVClient(
            url=account["url"],
            username=account["username"],
            password=account["password"],
        )
        for cal in client.get_calendars():
            name = cal.get_display_name() or str(cal.url).rstrip("/").rsplit("/", 1)[-1]
            if len(ACCOUNTS) > 1:
                name = f"{account['name']}/{name}"
            found[name] = cal
    return found


def pick(name):
    found = calendars()
    if name:
        if name not in found:
            raise ValueError(f"no calendar {name!r}; there are: {', '.join(found)}")
        return found[name]
    if len(found) == 1:
        return next(iter(found.values()))
    raise ValueError(f"say which calendar: {', '.join(found)}")


def when(text):
    """YYYY-MM-DD HH:MM in local time, or YYYY-MM-DD for a whole day."""
    text = text.strip()
    if len(text) == 10:
        return date.fromisoformat(text)
    return datetime.strptime(text, "%Y-%m-%d %H:%M").replace(tzinfo=ZONE)


def show(value):
    if isinstance(value, datetime):
        if value.tzinfo:
            value = value.astimezone(ZONE)
        return value.strftime("%Y-%m-%d %H:%M")
    return value.isoformat()


def find(uid):
    for name, cal in calendars().items():
        try:
            return name, cal.get_event_by_uid(uid)
        except NotFoundError:
            continue
    raise ValueError(f"no event {uid}")


@server.tool(name="calendars")
def list_calendars() -> list[str]:
    """Names of Dylan's calendars."""
    return list(calendars())


@server.tool()
def events(start: str, days: int = 7, calendar: str = "") -> list[dict]:
    """Events from START (YYYY-MM-DD) for DAYS days, repeats expanded, on
    one calendar or all of them."""
    first = datetime.combine(date.fromisoformat(start), datetime.min.time(), ZONE)
    last = first + timedelta(days=days)
    chosen = {calendar: pick(calendar)} if calendar else calendars()
    found = []
    for name, cal in chosen.items():
        for event in cal.search(start=first, end=last, event=True, expand=True):
            c = event.get_icalendar_component()
            found.append(
                {
                    "uid": str(c.get("uid")),
                    "calendar": name,
                    "start": show(c.decoded("dtstart")),
                    "end": show(c.decoded("dtend")) if "dtend" in c else None,
                    "summary": str(c.get("summary", "")),
                    "location": str(c.get("location", "")) or None,
                    "repeats": "rrule" in c or "recurrence-id" in c,
                }
            )
    return sorted(found, key=lambda e: e["start"])


@server.tool()
def add_event(
    summary: str,
    start: str,
    end: str = "",
    calendar: str = "",
    location: str = "",
    notes: str = "",
    repeat: str = "",
) -> dict:
    """Add an event. START and END are YYYY-MM-DD HH:MM, or YYYY-MM-DD for
    an all-day event; a timed event without END lasts an hour, an all-day
    one a day. REPEAT is daily, weekly, monthly or yearly."""
    begin = when(start)
    if end:
        finish = when(end)
    elif isinstance(begin, datetime):
        finish = begin + timedelta(hours=1)
    else:
        finish = begin + timedelta(days=1)
    if repeat and repeat not in REPEATS:
        raise ValueError(f"repeat is one of {', '.join(REPEATS)}")
    cal = pick(calendar)
    event = cal.add_event(
        dtstart=begin,
        dtend=finish,
        summary=summary,
        location=location or None,
        description=notes or None,
        rrule={"FREQ": repeat.upper()} if repeat else None,
    )
    c = event.get_icalendar_component()
    return {"uid": str(c.get("uid")), "start": show(begin), "end": show(finish)}


@server.tool()
def change_event(
    uid: str,
    summary: str = "",
    start: str = "",
    end: str = "",
    location: str = "",
    notes: str = "",
) -> str:
    """Change an event by UID; only the fields given change. A repeating
    event changes as a whole series."""
    _, event = find(uid)
    with event.edit_icalendar_component() as c:
        if start:
            begin = when(start)
            if not end and "dtend" in c:
                end_value = c.decoded("dtend") - c.decoded("dtstart") + begin
                c.pop("dtend")
                c.add("dtend", end_value)
            c.pop("dtstart")
            c.add("dtstart", begin)
        if end:
            c.pop("dtend", None)
            c.add("dtend", when(end))
        for key, value in (("summary", summary), ("location", location), ("description", notes)):
            if value:
                c.pop(key, None)
                c.add(key, value)
    event.save()
    return "changed"


@server.tool()
def cancel_event(uid: str) -> str:
    """Delete an event by UID; a repeating event goes as a whole series."""
    _, event = find(uid)
    event.delete()
    return "cancelled"


if __name__ == "__main__":
    server.run()
