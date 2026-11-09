"""MCP server (stdio, JSON-RPC, standard library only) for the Alpaca PAPER account.

Orders are two-step: propose_order / propose_exit / propose_replace validate and return a proposal id, commit_order places it.
Run: PYTHONPATH=~/Developer/market-alerts python3 -m market_alerts.mcp_server
"""
import json
import os
import sys

from . import earnings, logic, quant, trading
from .alpaca import Alpaca, AlpacaError, load_keys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFG_PATH = os.path.join(ROOT, "watchlist.json")


def cfg():
    with open(CFG_PATH) as f:
        return json.load(f)


def save_cfg(c):
    with open(CFG_PATH, "w") as f:
        json.dump(c, f, indent=2, ensure_ascii=False)
        f.write("\n")


_api = None


def api():
    global _api
    if _api is None:
        _api = Alpaca(load_keys())
    return _api


def S(**props):
    return {"type": "object", "properties": props}


STR, NUM = {"type": "string"}, {"type": "number"}
TOOLS = [
    ("account", "Paper account: equity, cash, buying power, today's P/L.", S()),
    ("positions", "Open positions in the paper account with P/L.", S()),
    ("quote", "Last price, previous close and % change for symbols.",
     dict(S(symbols={"type": "array", "items": STR}), required=["symbols"])),
    ("brief", "Today's market brief (account, positions, watchlist moves, news) as Markdown.", S()),
    ("watchlist", "Show the watchlist, alert rules and trading limits.", S()),
    ("update_watchlist", "Change the watchlist and alert rules. Levels: [{symbol, above, below}], 0 = off.",
     S(add={"type": "array", "items": STR}, remove={"type": "array", "items": STR},
       move_alert_pct=NUM, levels={"type": "array", "items": {"type": "object"}})),
    ("orders", "Recent paper orders. status: open | closed | all.", S(status=STR, limit=NUM)),
    ("propose_order", "Step 1 of 2: validate a PAPER order and return a proposal id and summary. Nothing is placed. "
     "type: market | limit (limit_price) | stop (stop_price) | stop_limit (stop_price + limit_price) | trailing_stop "
     "(trail_percent or trail_price). take_profit_price and/or stop_loss_price (+ optional stop_loss_limit_price) on a market or "
     "limit entry attach exit legs: both = bracket, one = OTO (whole shares, qty; time_in_force defaults to gtc so the legs outlive the day). "
     "Short: side sell without holding the stock opens a short (shortable, easy-to-borrow stocks, whole shares; for a short the take profit "
     "is below and the stop loss above the entry). Leverage: orders may use margin up to the account's multiplier (or trading.max_leverage); "
     "the summary shows the exposure after the order. Leveraged ETFs (TQQQ, SQQQ, …) are ordinary symbols. "
     "Show the summary to the user and only call commit_order after they explicitly confirm.",
     dict(S(symbol=STR, side={"type": "string", "enum": list(trading.SIDES)}, qty=NUM, notional_usd=NUM,
            type={"type": "string", "enum": list(trading.TYPES)}, limit_price=NUM, stop_price=NUM,
            trail_percent=NUM, trail_price=NUM, take_profit_price=NUM, stop_loss_price=NUM, stop_loss_limit_price=NUM,
            time_in_force={"type": "string", "enum": list(trading.TIFS)}), required=["symbol", "side"])),
    ("option_chain", "Option chain of an underlying (stock or ETF): contracts with bid/ask, last, implied volatility, delta and "
     "open interest. Filter with expiration (YYYY-MM-DD) or expiration_from/expiration_to, type call | put, strike_min/strike_max; "
     "without filters the nearest expirations around the current price. The symbol column is the OCC contract for propose_option_order.",
     dict(S(underlying=STR, expiration=STR, expiration_from=STR, expiration_to=STR, type={"type": "string", "enum": ["call", "put"]},
            strike_min=NUM, strike_max=NUM, limit=NUM), required=["underlying"])),
    ("propose_option_order", "Step 1 of 2: a PAPER option order, one leg. The contract: contract (OCC symbol from option_chain, e.g. "
     "AAPL261120C00230000) or underlying + expiration + type (call/put) + strike. side buy (to open, or to close a short) | sell (to close "
     "contracts you hold; naked shorts are not allowed). qty = contracts (× 100 shares); type limit (limit_price per share, default) | "
     "market; DAY only. Nothing is placed; commit_order places it after the user confirms.",
     dict(S(contract=STR, underlying=STR, expiration=STR, type={"type": "string", "enum": ["call", "put"]}, strike=NUM,
            side={"type": "string", "enum": list(trading.SIDES)}, qty=NUM, order_type={"type": "string", "enum": ["limit", "market"]},
            limit_price=NUM), required=["side", "qty"])),
    ("news", "Latest market news for symbols (Alpaca/Benzinga, live, with timestamps), newest first. Use this for today's news "
     "instead of a web search. days (default 3), limit (default 10).",
     dict(S(symbols={"type": "array", "items": STR}, days=NUM, limit=NUM), required=["symbols"])),
    ("earnings", "Next earnings date for symbols (Nasdaq / Zacks): date, before open or after close, fiscal quarter, EPS forecast; "
     "marked estimated until the company confirms it.", dict(S(symbols={"type": "array", "items": STR}), required=["symbols"])),
    ("option_calc", "Black-Scholes price and greeks (delta, gamma, theta per day, vega and rho per 1 %) of an option, and the "
     "probability it ends in the money. contract (OCC symbol) fills in spot, strike, expiration and the implied volatility from the "
     "market price; or give kind, strike, expiration, spot and iv (decimal) or price (then iv is solved). Use it instead of estimating.",
     S(contract=STR, kind={"type": "string", "enum": ["call", "put"]}, strike=NUM, expiration=STR, spot=NUM, iv=NUM, price=NUM, rate=NUM)),
    ("strategy_payoff", "P/L of an options strategy (spread, straddle, covered call, …) at the first expiration: table over prices, "
     "break-evens, max profit / max loss (null = unlimited), probability of profit, net cost. legs: [{contract (OCC) or kind + strike + "
     "expiration, qty (+ long, − short contracts; stock legs kind stock, qty in shares), price per share (default: current mid)}]. "
     "positions: true uses the open positions in `underlying` (stock and options) instead.",
     dict(S(underlying=STR, legs={"type": "array", "items": {"type": "object"}}, positions={"type": "boolean"}), required=["underlying"])),
    ("position_size", "How many shares to trade so that hitting the stop loses at most risk_pct % of equity (default 1 %) or risk_usd; "
     "with notional, % of equity, leverage and margin use. Long when stop < entry, short when above.",
     dict(S(symbol=STR, entry=NUM, stop=NUM, risk_pct=NUM, risk_usd=NUM), required=["entry", "stop"])),
    ("backtest", "Backtest a simple daily strategy on a symbol's history: buy_hold, sma_cross (fast/slow, default 20/50) or breakout "
     "(lookback days, default 20). years of history (default 2). Returns return, yearly return, max drawdown, Sharpe, trades vs buy and hold.",
     dict(S(symbol=STR, strategy={"type": "string", "enum": ["buy_hold", "sma_cross", "breakout"]}, years=NUM, fast=NUM, slow=NUM,
            lookback=NUM), required=["symbol"])),
    ("propose_exit", "Step 1 of 2: protect an OPEN position with a take profit and/or stop loss (both = OCO, one cancels the "
     "other) or a trailing stop. Exits at most the position (qty defaults to all of it), never opens a new one; "
     "time_in_force defaults to gtc. Nothing is placed; commit_order places it after the user confirms.",
     dict(S(symbol=STR, qty=NUM, take_profit_price=NUM, stop_loss_price=NUM, stop_loss_limit_price=NUM,
            trail_percent=NUM, trail_price=NUM, time_in_force={"type": "string", "enum": list(trading.TIFS)}), required=["symbol"])),
    ("propose_replace", "Step 1 of 2: change an OPEN order, e.g. move a stop loss (stop_price) or take profit (limit_price), "
     "qty, trail (trailing stop's percent/price) or time_in_force. order_id from orders (bracket legs are listed inside "
     "their parent). Nothing changes until commit_order after the user confirms.",
     dict(S(order_id=STR, qty=NUM, limit_price=NUM, stop_price=NUM, trail=NUM,
            time_in_force={"type": "string", "enum": list(trading.TIFS)}), required=["order_id"])),
    ("commit_order", "Step 2 of 2: place (or, for propose_replace, apply) a proposed PAPER order. Only after the user confirmed that exact proposal.",
     dict(S(proposal_id=STR), required=["proposal_id"])),
    ("cancel_order", "Cancel an open paper order by its order id.", dict(S(order_id=STR), required=["order_id"])),
]


# tools that only look: clients (Brain) run them without asking
READ_ONLY = {"account", "positions", "quote", "brief", "watchlist", "orders", "option_chain", "option_calc", "strategy_payoff", "news", "earnings",
             "position_size", "backtest"}


def short(o):
    keys = ("id", "symbol", "side", "type", "order_class", "qty", "notional", "limit_price", "stop_price", "trail_percent",
            "trail_price", "time_in_force", "status", "filled_qty", "filled_avg_price", "submitted_at")
    out = {k: o.get(k) for k in keys if o.get(k) not in (None, "", "simple")}
    if o.get("legs"):
        out["legs"] = [short(l) for l in o["legs"]]
    return out


def run_tool(name, a):
    c = cfg()
    if name == "account":
        x = api().account()
        eq, last = float(x["equity"]), float(x["last_equity"])
        return {"equity": eq, "cash": float(x["cash"]), "buying_power": float(x["buying_power"]),
                "pl_today": round(eq - last, 2), "status": x.get("status"), "paper": True,
                "margin_multiplier": float(x.get("multiplier") or 1), "shorting_enabled": x.get("shorting_enabled"),
                "options_level": x.get("options_trading_level"), "options_buying_power": float(x.get("options_buying_power") or 0)}
    if name == "positions":
        return [{k: p.get(k) for k in ("symbol", "asset_class", "side", "qty", "avg_entry_price", "current_price", "market_value", "unrealized_pl", "unrealized_plpc")}
                for p in api().positions()]
    if name == "quote":
        syms = [s.upper().replace(" ", "") for s in a.get("symbols", [])][:50]
        opts = [s for s in syms if trading.is_occ(s)]
        out = logic.moves(api().snapshots([s for s in syms if s not in opts])) if len(opts) < len(syms) else {}
        for o in opts:   # option contracts: quote from the options snapshots
            out[o] = option_quote(o)
        return out
    if name == "brief":
        syms = c["symbols"]
        mv = logic.moves(api().snapshots(syms))
        news = logic.pick_news(api().news(syms, limit=50), set(syms), c.get("news_per_symbol", 2))
        import datetime as dt
        return logic.brief(dt.date.today().isoformat(), mv, api().account(), api().positions(), news, c)
    if name == "watchlist":
        return {k: c.get(k) for k in ("symbols", "move_alert_pct", "levels", "trading")}
    if name == "update_watchlist":
        syms = [s for s in c["symbols"] if s not in {x.upper() for x in a.get("remove", [])}]
        syms += [x.upper() for x in a.get("add", []) if x.upper() not in syms]
        c["symbols"] = syms
        if "move_alert_pct" in a:
            c["move_alert_pct"] = float(a["move_alert_pct"])
        if "levels" in a:
            c["levels"] = [{"symbol": str(l["symbol"]).upper(), "above": float(l.get("above") or 0), "below": float(l.get("below") or 0)}
                           for l in a["levels"] if l.get("symbol")]
        save_cfg(c)
        return {k: c.get(k) for k in ("symbols", "move_alert_pct", "levels")}
    if name == "orders":
        st = a.get("status", "all")
        return [short(o) for o in api().list_orders(status=st, limit=int(a.get("limit", 20)))]
    if name == "propose_order" and trading.is_occ(str(a.get("symbol", "")).upper().replace(" ", "")):
        # an option contract: same flow as propose_option_order
        return run_tool("propose_option_order", dict(a, contract=a["symbol"], order_type=a.get("type", "limit")))
    if name == "propose_order":
        sym = str(a.get("symbol", "")).upper()
        asset = api().asset(sym)
        if not asset.get("tradable"):
            raise ValueError(f"{sym} is not tradable on Alpaca")
        price = logic.moves(api().snapshots([sym])).get(sym, {}).get("last")
        if a.get("type", "market") == "market" and not price:
            raise ValueError(f"no recent price for {sym}")
        body, summary, est = trading.build(a, price, c.get("trading", {}))
        summary += trading.short_check(body, api().position(sym), asset)
        summary += trading.leverage_check(est, api().account(), api().positions(), c.get("trading", {}))
        pid = trading.propose(body, summary, c.get("trading", {}).get("proposal_minutes", 10))
        return {"proposal_id": pid, "summary": summary, "estimated_usd": round(est, 2),
                "next": "Show the summary to the user. Call commit_order only after they confirm this exact proposal."}
    if name == "option_chain":
        return option_chain(a)
    if name == "news":
        import datetime as dt
        syms = [x.upper() for x in a["symbols"]][:20]
        since = (dt.datetime.utcnow() - dt.timedelta(days=float(a.get("days") or 3))).strftime("%Y-%m-%dT%H:%M:%SZ")
        items = api()._get("https://data.alpaca.markets", "/v1beta1/news", symbols=",".join(syms), start=since,
                           limit=min(int(a.get("limit") or 10), 50)).get("news", [])
        return [{"at": n.get("created_at"), "headline": n.get("headline"), "summary": (n.get("summary") or "")[:300],
                 "symbols": n.get("symbols"), "source": n.get("source"), "url": n.get("url")} for n in items]
    if name == "earnings":
        out = []
        for x in a["symbols"][:20]:
            try:
                out.append(earnings.next_earnings(x))
            except Exception as e:  # one symbol failing shouldn't hide the others
                out.append({"symbol": x.upper(), "error": str(e)[:120]})
        return out
    if name in ("option_calc", "strategy_payoff", "position_size", "backtest"):
        return calc(name, a, c)
    if name == "propose_option_order":
        sym = a.get("contract") or trading.occ(a["underlying"], a["expiration"], a["type"], a["strike"])
        sym = str(sym).upper().replace(" ", "")
        try:
            contract = api().option_contract(sym)
        except AlpacaError as e:
            raise ValueError(f"no option contract {sym} (check the expiration and strike with option_chain)") from e
        quote = option_quote(sym, contract)
        positions = api().positions()
        held = sum(float(p.get("qty") or 0) for p in positions if p.get("symbol") == sym)
        body, summary, est = trading.build_option(dict(a, type=a.get("order_type", "limit")), contract, quote, held, c.get("trading", {}),
                                                  covered=trading.coverage(sym, positions))
        pid = trading.propose(body, summary, c.get("trading", {}).get("proposal_minutes", 10))
        return {"proposal_id": pid, "summary": summary, "estimated_usd": round(est, 2),
                "next": "Show the summary to the user. Call commit_order only after they confirm this exact proposal."}
    if name == "propose_exit":
        sym = str(a.get("symbol", "")).upper()
        price = logic.moves(api().snapshots([sym])).get(sym, {}).get("last")
        body, summary = trading.build_exit(a, api().position(sym), price)
        pid = trading.propose(body, summary, c.get("trading", {}).get("proposal_minutes", 10))
        return {"proposal_id": pid, "summary": summary,
                "next": "Show the summary to the user. Call commit_order only after they confirm this exact proposal."}
    if name == "propose_replace":
        body, summary = trading.build_replace(a, api().order(a["order_id"]))
        pid = trading.propose(body, summary, c.get("trading", {}).get("proposal_minutes", 10), replace_id=a["order_id"])
        return {"proposal_id": pid, "summary": summary,
                "next": "Show the summary to the user. Call commit_order only after they confirm this exact proposal."}
    if name == "commit_order":
        prop = trading.take(a["proposal_id"])
        if prop.get("replace_id"):
            order = api().replace_order(prop["replace_id"], prop["body"])
            trading.log({"event": "replaced", "summary": prop["summary"], "order": short(order)})
            return {"changed": prop["summary"], "order": short(order)}
        order = api().place_order(prop["body"])
        trading.log({"event": "placed", "summary": prop["summary"], "order": short(order)})
        return {"placed": prop["summary"], "order": short(order)}
    if name == "cancel_order":
        api().cancel_order(a["order_id"])
        trading.log({"event": "cancelled", "order_id": a["order_id"]})
        return {"cancelled": a["order_id"]}
    raise ValueError(f"unknown tool {name}")


def _spot(sym):
    return logic.moves(api().snapshots([sym])).get(sym, {}).get("last")


def _leg(l, und):
    """A strategy leg with strike, expiration, iv and price filled in from the market."""
    if str(l.get("kind", "")).lower() == "stock":
        return {"kind": "stock", "qty": float(l["qty"]), "price": float(l.get("price") or _spot(und))}
    sym = (l.get("contract") or trading.occ(und, l["expiration"], l["kind"], l["strike"])).upper()
    _, exp, kind, strike = trading.parse_occ(sym)
    q = option_quote(sym)
    mid = (q["bid"] + q["ask"]) / 2 if q.get("bid") and q.get("ask") else q.get("last")
    price = float(l.get("price") or mid or 0)
    iv = l.get("iv") or (mid and quant.implied_vol(kind, mid, _spot(und), strike, quant.years(exp))) or 0.4
    return {"kind": kind, "strike": strike, "expiration": exp, "qty": float(l["qty"]), "price": price, "iv": float(iv), "contract": sym}


def calc(name, a, c):
    if name == "option_calc":
        if a.get("contract"):
            sym = a["contract"].upper().replace(" ", "")
            und, exp, kind, strike = trading.parse_occ(sym)
            q = option_quote(sym)
            price = a.get("price") or ((q["bid"] + q["ask"]) / 2 if q.get("bid") and q.get("ask") else q.get("last"))
        else:
            und, exp, kind, strike, price = None, a["expiration"], a["kind"], float(a["strike"]), a.get("price")
        spot = float(a.get("spot") or _spot(und))
        t, r = quant.years(exp), float(a.get("rate") or 0.04)
        iv = a.get("iv") or (price and quant.implied_vol(kind, float(price), spot, strike, t, r))
        if not iv:
            raise ValueError("give iv, or a price (market price of the option) to solve it from")
        g = quant.bs(kind, spot, strike, t, float(iv), r)
        itm = quant.prob_above(spot, strike, t, float(iv), r)
        return {"spot": spot, "strike": strike, "expiration": exp, "kind": kind, "days": round(t * quant.YEAR, 1), "iv": round(float(iv), 4),
                "market_price": price, **{k: round(v, 4) for k, v in g.items()},
                "prob_itm": round(itm if kind == "call" else 1 - itm, 3), "per_contract": "× 100 for one contract"}
    if name == "strategy_payoff":
        und = a["underlying"].upper()
        if a.get("positions"):
            legs = []
            for p in api().positions():
                s = p["symbol"]
                if s == und:
                    legs.append({"kind": "stock", "qty": float(p["qty"]), "price": float(p["avg_entry_price"])})
                elif trading.is_occ(s) and trading.parse_occ(s)[0] == und:
                    legs.append({"contract": s, "qty": float(p["qty"]), "price": float(p["avg_entry_price"])})
            if not legs:
                raise ValueError(f"no open positions in {und}")
        else:
            legs = a.get("legs") or []
        full = [_leg(l, und) for l in legs]
        out = quant.payoff(full, _spot(und))
        return {"underlying": und, "spot": _spot(und), "legs": [{k: v for k, v in l.items() if k != "t"} for l in full], **out}
    if name == "position_size":
        acct = api().account()
        lim = c.get("trading", {})
        out = quant.position_size(float(acct["equity"]), float(a["entry"]), float(a["stop"]), a.get("risk_pct"), a.get("risk_usd"),
                                  float(lim.get("max_leverage") or acct.get("multiplier") or 1), float(acct["cash"]))
        cap = float(lim.get("max_order_usd") or 0)
        if cap and out["notional_usd"] > cap:
            out["over_max_order_usd"] = f"{out['notional_usd']:,.0f} USD is over max_order_usd {cap:,.0f}: at most {int(cap // float(a['entry']))} shares per order"
        return dict(out, symbol=a.get("symbol"), equity=float(acct["equity"]))
    if name == "backtest":
        import datetime as dt
        sym = a["symbol"].upper()
        start = (dt.date.today() - dt.timedelta(days=int(365 * float(a.get("years") or 2)))).isoformat()
        bars = api().bars(sym, start)
        return dict(quant.backtest(bars, a.get("strategy", "buy_hold"), int(a.get("fast") or 20), int(a.get("slow") or 50),
                                   int(a.get("lookback") or 20)), symbol=sym, start=start)
    raise ValueError(name)


def option_quote(sym, contract=None):
    """bid / ask / last of one option contract."""
    k = contract or api().option_contract(sym)
    snap = api().option_snapshots(k["underlying_symbol"], expiration_date=k["expiration_date"], type=k["type"],
                                  strike_price_gte=k["strike_price"], strike_price_lte=k["strike_price"]).get(sym, {})
    q = snap.get("latestQuote") or {}
    return {"bid": q.get("bp"), "ask": q.get("ap"), "last": (snap.get("latestTrade") or {}).get("p"), "name": k.get("name")}


def option_chain(a):
    und = str(a["underlying"]).upper()
    f = {"type": a.get("type"), "strike_price_gte": a.get("strike_min"), "strike_price_lte": a.get("strike_max")}
    if a.get("expiration"):
        f["expiration_date"] = a["expiration"]
    else:
        f["expiration_date_gte"], f["expiration_date_lte"] = a.get("expiration_from"), a.get("expiration_to")
    if not (f["strike_price_gte"] or f["strike_price_lte"]):
        # around the money: ±15 % of the last price
        last = logic.moves(api().snapshots([und])).get(und, {}).get("last")
        if last:
            f["strike_price_gte"], f["strike_price_lte"] = round(last * 0.85, 2), round(last * 1.15, 2)
    limit = min(int(a.get("limit") or 40), 200)
    contracts = api().option_contracts(und, limit=limit, **f)
    snaps = api().option_snapshots(und, limit=1000, **{k: v for k, v in f.items() if k != "expiration_date_gte" or v})
    rows = []
    for k in sorted(contracts, key=lambda x: (x["expiration_date"], x["type"], float(x["strike_price"]))):
        s = snaps.get(k["symbol"], {})
        q, g = s.get("latestQuote") or {}, s.get("greeks") or {}
        rows.append({"symbol": k["symbol"], "expiration": k["expiration_date"], "type": k["type"], "strike": float(k["strike_price"]),
                     "bid": q.get("bp"), "ask": q.get("ap"), "last": (s.get("latestTrade") or {}).get("p"),
                     "iv": s.get("impliedVolatility") and round(s["impliedVolatility"], 3), "delta": g.get("delta") and round(g["delta"], 3),
                     "open_interest": k.get("open_interest")})
    return {"underlying": und, "contracts": rows, "note": "Prices per share; one contract = 100 shares. Indicative (delayed) quotes on the free plan."}


def reply(mid, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": mid}
    msg.update({"error": error} if error else {"result": result})
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(msg):
    method, mid, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
    if mid is None:
        return  # notification
    if method == "initialize":
        return reply(mid, {"protocolVersion": params.get("protocolVersion", "2024-11-05"),
                           "capabilities": {"tools": {}},
                           "serverInfo": {"name": "market-alerts", "version": "1.0.0"},
                           "instructions": "Alpaca PAPER trading only. Orders are two-step: propose_order (stocks/ETFs, also shorts and margin) / propose_option_order (options; option_chain lists contracts) / propose_exit (stop loss, take profit, trailing stop) / propose_replace, show the summary, "
                                           "commit_order only after explicit user confirmation. On a paper account the assistant may recommend and draft trades from computed EV and the trading plan's rules; it never places one without that confirmation."})
    if method == "ping":
        return reply(mid, {})
    if method == "tools/list":
        return reply(mid, {"tools": [{"name": n, "description": d, "inputSchema": s, **({"annotations": {"readOnlyHint": True}} if n in READ_ONLY else {})}
                                     for n, d, s in TOOLS]})
    if method == "tools/call":
        try:
            out = run_tool(params.get("name"), params.get("arguments") or {})
            text = out if isinstance(out, str) else json.dumps(out, indent=1, ensure_ascii=False)
            return reply(mid, {"content": [{"type": "text", "text": text}]})
        except (ValueError, KeyError, AlpacaError) as e:
            return reply(mid, {"content": [{"type": "text", "text": f"Error: {e}"}], "isError": True})
    reply(mid, error={"code": -32601, "message": f"method not found: {method}"})


def main():
    for line in sys.stdin:
        line = line.strip()
        if line:
            try:
                handle(json.loads(line))
            except Exception as e:  # keep the server alive
                sys.stderr.write(f"market-alerts mcp: {e!r}\n")


if __name__ == "__main__":
    main()
