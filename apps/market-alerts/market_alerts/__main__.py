"""market-alerts: daily brief, price alerts and a paper-trade log from an Alpaca paper account.

usage: python3 -m market_alerts brief | alerts | trades [--dry-run]
"""
import csv
import datetime as dt
import json
import os
import subprocess
import sys

from . import logic
from .alpaca import Alpaca, load_keys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = os.path.expanduser("~/.local/state/market-alerts/sent.json")


def notify(title, text):
    # AppleScript reads JSON-style "..." strings, but not \uXXXX escapes
    q = lambda s: json.dumps(s, ensure_ascii=False)
    script = f'display notification {q(text)} with title {q(title)} sound name "Glass"'
    subprocess.run(["osascript", "-e", script], check=False)


def load_cfg():
    with open(os.path.join(ROOT, "watchlist.json")) as f:
        cfg = json.load(f)
    cfg["brief_folder"] = os.path.expanduser(cfg["brief_folder"])
    return cfg


def cmd_brief(api, cfg, dry):
    syms = cfg["symbols"]
    mv = logic.moves(api.snapshots(syms))
    news = logic.pick_news(api.news(syms, limit=50), set(syms), cfg.get("news_per_symbol", 2))
    day = dt.date.today().isoformat()
    md = logic.brief(day, mv, api.account(), api.positions(), news, cfg)
    if dry:
        print(md)
        return
    os.makedirs(cfg["brief_folder"], exist_ok=True)
    path = os.path.join(cfg["brief_folder"], f"{day}.md")
    with open(path, "w") as f:
        f.write(md)
    top = sorted(mv.items(), key=lambda kv: -abs(kv[1]["pct"]))[:3]
    notify("Market brief", " · ".join(f"{s} {m['pct']:+.1f}%" for s, m in top) or "ready")
    print("wrote", path)


def cmd_alerts(api, cfg, dry):
    if not dry and not api.clock().get("is_open"):
        return
    day = dt.date.today().isoformat()
    try:
        with open(STATE) as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}
    sent = set(state.get(day, []))
    new = logic.alerts(logic.moves(api.snapshots(cfg["symbols"])), cfg, sent)
    for key, text in new:
        print("ALERT", text)
        if not dry:
            notify("Market alert", text)
            sent.add(key)
    if not dry:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE, "w") as f:
            json.dump({day: sorted(sent)}, f)   # keep only today


def cmd_trades(api, cfg, dry):
    rows = [o for o in api.orders() if o.get("filled_at")]
    path = os.path.join(cfg["brief_folder"], "paper-trades.csv")
    fields = ["filled_at", "symbol", "side", "filled_qty", "filled_avg_price", "type", "id"]
    if dry:
        for o in rows:
            print(",".join(str(o.get(k, "")) for k in fields))
        return
    os.makedirs(cfg["brief_folder"], exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {len(rows)} trades to {path}")


def main(argv):
    if not argv or argv[0] not in ("brief", "alerts", "trades"):
        raise SystemExit(__doc__)
    api, cfg = Alpaca(load_keys()), load_cfg()
    {"brief": cmd_brief, "alerts": cmd_alerts, "trades": cmd_trades}[argv[0]](api, cfg, "--dry-run" in argv)


if __name__ == "__main__":
    main(sys.argv[1:])
