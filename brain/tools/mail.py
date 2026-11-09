#!/usr/bin/env python3
"""Reads Thunderbird's local mbox files and prints one JSON line per message for Brain's search by meaning.

usage: mail.py --since YYYY-MM-DD <account> <folder> <mbox path> [<account> <folder> <path> ...]

Skips messages Thunderbird marked deleted, bulk mail (List-Unsubscribe / Precedence: bulk), automatic notifications
(no-reply senders) and anything older than --since.
The text is the plain body (HTML converted) without quoted replies, cut to 4000 characters. Everything runs locally.
"""
import email
import email.policy
import html
import json
import re
import sys
from email.parser import BytesHeaderParser
from email.utils import parseaddr, parsedate_to_datetime

AUTOMATED = re.compile(r"^(no-?reply|do-?not-?reply|notifications?|mailer-daemon|postmaster|bounce|calendar-notification|support@todoist|.*@(todoist\.com|calendly\.com|google\.com|accounts\.google\.com|linkedin\.com|facebookmail\.com|github\.com|stripe\.com|vercel\.com|supabase\.(io|com)))", re.I)
QUOTE_CUT = re.compile(
    r"^(On .{5,200} wrote:|.{0,200}(napísal|napísala|napsal|napsala|napisał|schrieb)\(?a?\)?:\s*$|-{2,} ?(Original Message|Pôvodná správa|Původní zpráva|Forwarded message)|Od: .+|From: .+@.+)",
    re.I | re.M)


def text_of(msg):
    part = msg.get_body(preferencelist=("plain", "html"))
    if part is None:
        return ""
    try:
        t = part.get_content()
    except Exception:
        t = (part.get_payload(decode=True) or b"").decode("utf-8", "replace")
    if part.get_content_type() == "text/html":
        t = re.sub(r"(?is)<(script|style).*?</\1>", " ", t)
        t = re.sub(r"(?i)<br\s*/?>|</p>|</div>|</tr>|</li>", "\n", t)
        t = html.unescape(re.sub(r"<[^>]+>", " ", t))
    m = QUOTE_CUT.search(t)
    if m and m.start() > 40:
        t = t[: m.start()]
    t = "\n".join(l for l in t.splitlines() if not l.lstrip().startswith(">"))
    t = re.sub(r"[ \t ]+", " ", t)
    return re.sub(r"\n\s*\n+", "\n\n", t).strip()[:4000]


def messages(path):
    """Raw messages of an mbox file, split on the 'From ' separator lines."""
    buf = []
    with open(path, "rb") as f:
        for line in f:
            if line.startswith(b"From ") and buf:
                yield b"".join(buf)
                buf = []
            if not (line.startswith(b"From ") and not buf):
                buf.append(line)
        if buf:
            yield b"".join(buf)


def main():
    args = sys.argv[1:]
    since = args[args.index("--since") + 1]
    rest = [a for i, a in enumerate(args) if a != "--since" and (i == 0 or args[i - 1] != "--since")]
    hp = BytesHeaderParser(policy=email.policy.compat32)
    for i in range(0, len(rest), 3):
        account, folder, path = rest[i: i + 3]
        try:
            gen = messages(path)
            for raw in gen:
                h = hp.parsebytes(raw)
                try:
                    if int(h.get("X-Mozilla-Status", "0") or "0", 16) & 0x0008:   # expunged/deleted
                        continue
                except ValueError:
                    pass
                if h.get("List-Unsubscribe") or (h.get("Precedence", "").lower() in ("bulk", "list", "junk")):
                    continue
                try:
                    d = parsedate_to_datetime(h.get("Date"))
                    day = d.date().isoformat()
                except Exception:
                    continue
                if day < since:
                    continue
                msg = email.message_from_bytes(raw, policy=email.policy.default)
                try:
                    body = text_of(msg)
                except Exception:
                    body = ""
                mid = (h.get("Message-ID") or "").strip() or f"{account}/{folder}/{day}/{hash(raw[:2000])}"
                name, addr = parseaddr(str(msg.get("From", "")))
                if AUTOMATED.match(addr or ""):
                    continue
                print(json.dumps({
                    "id": mid, "account": account, "folder": folder, "date": day,
                    "from": name or addr, "from_email": addr.lower(),
                    "to": str(msg.get("To", ""))[:300], "subject": str(msg.get("Subject", "")).strip()[:300],
                    "text": body,
                }, ensure_ascii=False), flush=False)
        except FileNotFoundError:
            continue


if __name__ == "__main__":
    main()
