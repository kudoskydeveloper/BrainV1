"""Pure functions: turn Alpaca data into moves, alerts and a brief. No network here, so they can be tested offline."""


def moves(snapshots):
    """Per symbol: last price, previous close and % change from the previous close."""
    out = {}
    for sym, s in snapshots.items():
        prev = (s.get("prevDailyBar") or {}).get("c")
        last = (s.get("latestTrade") or {}).get("p") or (s.get("dailyBar") or {}).get("c")
        if prev and last:
            out[sym] = {"last": last, "prev": prev, "pct": (last - prev) / prev * 100}
    return out


def alerts(mv, cfg, already_sent):
    """Alerts to send now. already_sent holds keys sent today, so each rule fires once a day."""
    out = []
    limit = cfg.get("move_alert_pct") or 0
    for sym, m in mv.items():
        if limit and abs(m["pct"]) >= limit:
            out.append((f"move:{sym}:{'up' if m['pct'] > 0 else 'down'}",
                        f"{sym} {m['pct']:+.1f}% at {m['last']:.2f}"))
    for lv in cfg.get("levels", []):
        m = mv.get(lv.get("symbol"))
        if not m:
            continue
        if lv.get("above") and m["last"] >= lv["above"]:
            out.append((f"above:{lv['symbol']}:{lv['above']}", f"{lv['symbol']} above {lv['above']} (now {m['last']:.2f})"))
        if lv.get("below") and m["last"] <= lv["below"]:
            out.append((f"below:{lv['symbol']}:{lv['below']}", f"{lv['symbol']} below {lv['below']} (now {m['last']:.2f})"))
    return [(k, t) for k, t in out if k not in already_sent]


def brief(day, mv, account, positions, news, cfg):
    """Markdown daily brief."""
    lines = [f"# Market brief {day}", ""]
    if account:
        eq, last = float(account["equity"]), float(account["last_equity"])
        lines += ["## Paper account",
                  f"Equity {eq:,.2f} USD ({eq - last:+,.2f}, {(eq - last) / last * 100 if last else 0:+.2f}% today) · cash {float(account['cash']):,.2f}", ""]
    if positions:
        lines += ["| Position | Qty | Price | P/L | P/L % |", "|---|---:|---:|---:|---:|"]
        for p in positions:
            lines.append(f"| {p['symbol']} | {p['qty']} | {float(p['current_price']):.2f} | "
                         f"{float(p['unrealized_pl']):+,.2f} | {float(p['unrealized_plpc']) * 100:+.1f}% |")
        lines.append("")
    lines += ["## Watchlist", "| Symbol | Last | Prev close | Change |", "|---|---:|---:|---:|"]
    for sym in sorted(mv, key=lambda s: -abs(mv[s]["pct"])):
        m = mv[sym]
        flag = " ⚠️" if cfg.get("move_alert_pct") and abs(m["pct"]) >= cfg["move_alert_pct"] else ""
        lines.append(f"| {sym} | {m['last']:.2f} | {m['prev']:.2f} | {m['pct']:+.2f}%{flag} |")
    if news:
        lines += ["", "## News"]
        for n in news:
            syms = ", ".join(n.get("symbols", [])[:3])
            lines.append(f"- **{syms}**: [{n['headline']}]({n.get('url', '')})")
    lines += ["", "_Data: Alpaca paper account and IEX feed. For your own tracking, not advice._"]
    return "\n".join(lines) + "\n"


def pick_news(items, symbols, per_symbol):
    """At most per_symbol headlines per watched symbol, newest first, no repeats."""
    seen, count, out = set(), {}, []
    for n in items:
        hit = [s for s in n.get("symbols", []) if s in symbols and count.get(s, 0) < per_symbol]
        if hit and n["id"] not in seen:
            seen.add(n["id"])
            for s in hit:
                count[s] = count.get(s, 0) + 1
            out.append(n)
    return out
