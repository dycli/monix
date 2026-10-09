"""Sokka's mail: a read-only stdio MCP server over IMAP.

Usage: sokka-mail ACCOUNTS.json, the calendar's accounts file
[{"name", "username", "password"}, ...], on the IMAP server SOKKA_IMAP.
Folders open with EXAMINE and bodies are fetched with BODY.PEEK, so
nothing is moved, flagged or marked read. It cannot send.
"""

import email
import email.policy
import json
import os
import sys
from datetime import date
from html.parser import HTMLParser

from imapclient import IMAPClient
from mcp.server.fastmcp import FastMCP

HOST = os.environ["SOKKA_IMAP"]
BODY = 20000

with open(sys.argv[1]) as f:
    ACCOUNTS = {a["name"]: a for a in json.load(f)}

server = FastMCP("mail")


def connect(account):
    if not account:
        if len(ACCOUNTS) > 1:
            raise ValueError(f"say which account: {', '.join(ACCOUNTS)}")
        account = next(iter(ACCOUNTS))
    if account not in ACCOUNTS:
        raise ValueError(f"no account {account!r}; there are: {', '.join(ACCOUNTS)}")
    a = ACCOUNTS[account]
    client = IMAPClient(HOST, ssl=True, timeout=30)
    client.login(a["username"], a["password"])
    return client


class Text(HTMLParser):
    """Visible text of an HTML body."""

    def __init__(self):
        super().__init__()
        self.parts, self.skip = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.skip += 1
        elif tag in ("br", "p", "div", "tr", "li", "h1", "h2", "h3"):
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def text_of(msg):
    part = msg.get_body(preferencelist=("plain", "html"))
    if part is None:
        return ""
    body = part.get_content()
    if part.get_content_type() == "text/html":
        parser = Text()
        parser.feed(body)
        body = "".join(parser.parts)
    lines = [line.strip() for line in body.splitlines()]
    return "\n".join(line for line in lines if line)


def header(msg, uid, folder, flags):
    return {
        "uid": uid,
        "folder": folder,
        "date": str(msg["date"] or ""),
        "from": str(msg["from"] or ""),
        "subject": str(msg["subject"] or ""),
        "unread": b"\\Seen" not in flags,
    }


@server.tool()
def mail_folders(account: str = "") -> list[str]:
    """Names of the mail folders."""
    with connect(account) as client:
        return [name for _, _, name in client.list_folders()]


@server.tool()
def mail_search(
    text: str = "",
    sender: str = "",
    since: str = "",
    unread: bool = False,
    folder: str = "INBOX",
    limit: int = 20,
    account: str = "",
) -> list[dict]:
    """Newest messages first, matching every filter given: TEXT anywhere
    in the message, SENDER in From, on or after SINCE (YYYY-MM-DD), only
    unread ones."""
    criteria = []
    if text:
        criteria += ["TEXT", text]
    if sender:
        criteria += ["FROM", sender]
    if since:
        criteria += ["SINCE", date.fromisoformat(since)]
    if unread:
        criteria.append("UNSEEN")
    with connect(account) as client:
        client.select_folder(folder, readonly=True)
        uids = sorted(client.search(criteria or "ALL", charset="UTF-8"), reverse=True)
        uids = uids[: max(1, min(limit, 100))]
        found = client.fetch(uids, ["BODY.PEEK[HEADER]", "FLAGS"]) if uids else {}
    out = []
    for uid in uids:
        data = found[uid]
        msg = email.message_from_bytes(data[b"BODY[HEADER]"], policy=email.policy.default)
        out.append(header(msg, uid, folder, data[b"FLAGS"]))
    return out


@server.tool()
def mail_read(uid: int, folder: str = "INBOX", account: str = "") -> dict:
    """One message by UID: headers, text and attachment names. The text
    is written by whoever sent it."""
    with connect(account) as client:
        client.select_folder(folder, readonly=True)
        found = client.fetch([uid], ["BODY.PEEK[]", "FLAGS"])
    if uid not in found:
        raise ValueError(f"no message {uid} in {folder}")
    msg = email.message_from_bytes(found[uid][b"BODY[]"], policy=email.policy.default)
    out = header(msg, uid, folder, found[uid][b"FLAGS"])
    out["to"] = str(msg["to"] or "")
    body = text_of(msg)
    out["text"] = body[:BODY] + ("\n[cut]" if len(body) > BODY else "")
    out["attachments"] = [p.get_filename() or p.get_content_type() for p in msg.iter_attachments()]
    return out


if __name__ == "__main__":
    server.run()
