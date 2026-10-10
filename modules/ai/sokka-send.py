"""Sokka's one way out by mail: sends the message given on stdin as JSON
{"account", "to", "subject", "body"} from that account's address in
ACCOUNTS.json (the mail server's accounts file) over SMTP, TLS on 465, at
SOKKA_SMTP. Only Sokka itself runs it, after the person approved the
draft in the room; the model has no tool that reaches it.
"""

import json
import os
import smtplib
import sys
from email.message import EmailMessage

HOST = os.environ["SOKKA_SMTP"]

with open(sys.argv[1]) as f:
    ACCOUNTS = {a["name"]: a for a in json.load(f)}

m = json.load(sys.stdin)
name = m.get("account") or (next(iter(ACCOUNTS)) if len(ACCOUNTS) == 1 else None)
if name not in ACCOUNTS:
    sys.exit(f"no account {name!r}; there are: {', '.join(ACCOUNTS)}")
a = ACCOUNTS[name]

msg = EmailMessage()
msg["From"] = a["username"]
msg["To"] = m["to"]
msg["Subject"] = m["subject"]
msg.set_content(m["body"])

with smtplib.SMTP_SSL(HOST, 465, timeout=60) as s:
    s.login(a["username"], a["password"])
    s.send_message(msg)
print(f"Sent to {m['to']}.")
