"""Paper-order proposals: validate against the limits in watchlist.json, keep them until confirmed. No network here."""
import json
import os
import secrets
import time

PROPOSALS = os.path.expanduser("~/.local/state/market-alerts/proposals.json")
ORDER_LOG = os.path.expanduser("~/.local/state/market-alerts/orders.jsonl")
SIDES, TYPES, TIFS = ("buy", "sell"), ("market", "limit", "stop", "stop_limit", "trailing_stop"), ("day", "gtc")


def _num(a, key):
    """Optional positive number from the arguments. Raises ValueError."""
    v = a.get(key)
    if v is None or v == "":
        return None
    v = float(v)
    if v <= 0:
        raise ValueError(f"{key} must be positive")
    return v


def px(x):
    """Price as Alpaca wants it: 2 decimals from 1 USD up, 4 below."""
    return f"{x:.2f}" if x >= 1 else f"{x:.4f}"


def _check_side(side, ref, take_profit=None, stop_loss=None, what="entry"):
    """For a long (buy) take profit must be above ref and stop loss below; the other way round for a short (sell)."""
    if not ref:
        return
    up, down = (take_profit, stop_loss) if side == "buy" else (stop_loss, take_profit)
    if up is not None and up <= ref:
        raise ValueError(f"{'take_profit_price' if side == 'buy' else 'stop_loss_price'} {up:.2f} must be above the {what} {ref:.2f}")
    if down is not None and down >= ref:
        raise ValueError(f"{'stop_loss_price' if side == 'buy' else 'take_profit_price'} {down:.2f} must be below the {what} {ref:.2f}")


def _legs(body, side, ref, tp, sl, sl_limit, what):
    """Take-profit / stop-loss legs; returns the summary part."""
    if sl_limit is not None and sl is None:
        raise ValueError("stop_loss_limit_price needs stop_loss_price")
    _check_side(side, ref, tp, sl, what)
    if sl_limit is not None and ((side == "buy" and sl_limit > sl) or (side == "sell" and sl_limit < sl)):
        raise ValueError("stop_loss_limit_price must be at or beyond stop_loss_price (worse fill), else the stop may never fill")
    parts = []
    if tp is not None:
        body["take_profit"] = {"limit_price": px(tp)}
        parts.append(f"take profit {px(tp)}")
    if sl is not None:
        body["stop_loss"] = {"stop_price": px(sl), **({"limit_price": px(sl_limit)} if sl_limit is not None else {})}
        parts.append(f"stop loss {px(sl)}" + (f" (limit {px(sl_limit)})" if sl_limit is not None else ""))
    return ", ".join(parts)


def build(args, price, limits):
    """Check an order request and return the Alpaca order body plus a plain-language summary. Raises ValueError.

    type market | limit | stop | stop_limit | trailing_stop. take_profit_price / stop_loss_price (+ stop_loss_limit_price)
    attach exit legs to a market or limit entry: both = bracket, one = OTO."""
    sym = str(args.get("symbol", "")).upper().strip()
    side = args.get("side")
    typ = args.get("type", "market")
    has_legs = any(args.get(k) not in (None, "") for k in ("take_profit_price", "stop_loss_price"))
    # exit legs default to GTC: a DAY bracket's take profit and stop loss expire at the close and leave the position unprotected
    tif = args.get("time_in_force") or ("gtc" if has_legs else "day")
    qty = args.get("qty")
    notional = args.get("notional_usd")
    limit_price, stop_price = _num(args, "limit_price"), _num(args, "stop_price")
    trail_pct, trail_px = _num(args, "trail_percent"), _num(args, "trail_price")
    tp, sl, sl_limit = _num(args, "take_profit_price"), _num(args, "stop_loss_price"), _num(args, "stop_loss_limit_price")
    if not sym.replace(".", "").isalnum():
        raise ValueError("symbol is required")
    if side not in SIDES or typ not in TYPES or tif not in TIFS:
        raise ValueError(f"side must be {SIDES}, type {TYPES}, time_in_force {TIFS}")
    allowed = [s.upper() for s in limits.get("allowed_symbols") or []]
    if allowed and sym not in allowed:
        raise ValueError(f"{sym} is not in allowed_symbols {allowed}")
    if (qty is None) == (notional is None):
        raise ValueError("give exactly one of qty or notional_usd")
    if notional is not None and (typ != "market" or tp or sl):
        raise ValueError("notional_usd works with plain market orders only; use qty")
    if typ in ("limit", "stop_limit") and not limit_price:
        raise ValueError(f"{typ} orders need limit_price")
    if typ in ("stop", "stop_limit") and not stop_price:
        raise ValueError(f"{typ} orders need stop_price")
    if typ == "trailing_stop" and (trail_pct is None) == (trail_px is None):
        raise ValueError("trailing_stop needs exactly one of trail_percent or trail_price")
    if typ != "trailing_stop" and (trail_pct or trail_px):
        raise ValueError("trail_percent / trail_price are for type trailing_stop")
    if price and stop_price and typ in ("stop", "stop_limit"):
        # a buy stop sits above the market, a sell stop below; otherwise it would trigger at once
        if (side == "buy" and stop_price <= price) or (side == "sell" and stop_price >= price):
            raise ValueError(f"a {side} stop_price must be {'above' if side == 'buy' else 'below'} the last price {price:.2f}")
    if sl_limit is not None and sl is None:
        raise ValueError("stop_loss_limit_price needs stop_loss_price")
    if (tp or sl) and typ not in ("market", "limit"):
        raise ValueError("take_profit_price / stop_loss_price go with a market or limit entry")
    ref = {"limit": limit_price, "stop": stop_price, "stop_limit": limit_price}.get(typ) or float(price or 0)
    if qty is not None:
        if float(qty) <= 0:
            raise ValueError("qty must be positive")
        if (tp or sl or typ == "trailing_stop") and float(qty) != int(float(qty)):
            raise ValueError("bracket, OTO and trailing stop orders need whole shares")
        est = float(qty) * ref
    else:
        if float(notional) <= 0:
            raise ValueError("notional_usd must be positive")
        est = float(notional)
    cap = float(limits.get("max_order_usd") or 0)
    if cap and est > cap:
        raise ValueError(f"estimated {est:,.2f} USD is over max_order_usd {cap:,.0f}")
    body = {"symbol": sym, "side": side, "type": typ, "time_in_force": tif}
    body.update({"qty": str(qty)} if qty is not None else {"notional": str(notional)})
    if limit_price:
        body["limit_price"] = px(limit_price)
    if stop_price:
        body["stop_price"] = px(stop_price)
    if trail_pct:
        body["trail_percent"] = str(trail_pct)
    if trail_px:
        body["trail_price"] = px(trail_px)
    legs = ""
    if tp or sl:
        body["order_class"] = "bracket" if tp and sl else "oto"
        legs = _legs(body, side, ref, tp, sl, sl_limit, "entry price")
    amount = f"{qty} shares" if qty is not None else f"{float(notional):,.2f} USD of"
    at = {"market": f"market (last {ref:.2f})", "limit": f"limit {px(ref)}",
          "stop": f"stop {px(stop_price or 0)}", "stop_limit": f"stop {px(stop_price or 0)} / limit {px(limit_price or 0)}",
          "trailing_stop": f"trailing stop {f'{trail_pct:g} %' if trail_pct else px(trail_px or 0) + ' USD'}"}[typ]
    cls = f" [{body['order_class'].upper()}: {legs}]" if legs else ""
    summary = f"PAPER {side.upper()} {amount} {sym} at {at}, {tif.upper()}{cls}, est. {est:,.2f} USD"
    if legs and tif == "day":
        summary += " ⚠️ DAY: take profit and stop loss expire at today's close and the position is left unprotected"
    return body, summary, est


def short_check(body, position, asset):
    """A sell that opens or grows a short: the stock must be shortable and easy to borrow, whole shares, no notional.
    Returns the summary note ("" for an ordinary sell of shares held). Raises ValueError."""
    if body["side"] != "sell":
        return ""
    held = float((position or {}).get("qty") or 0)
    qty = float(body.get("qty") or 0)
    if "notional" in body and held <= 0:
        raise ValueError("a short sale needs qty (whole shares), not notional_usd")
    if held > 0 and qty <= held:
        return ""
    if not (asset.get("shortable") and asset.get("easy_to_borrow")):
        raise ValueError(f"{body['symbol']} can't be shorted on Alpaca (shortable={asset.get('shortable')}, easy_to_borrow={asset.get('easy_to_borrow')})")
    if qty != int(qty):
        raise ValueError("short sales need whole shares")
    new = qty - held if held > 0 else qty
    return f" ⚠️ SHORT: opens a short of {new:g} shares" + (f" (sells the {held:g} held, then shorts the rest)" if held > 0 else "") + \
        ("" if body.get("stop_loss") else "; the loss is unlimited if the price rises, so add a stop_loss_price")


def leverage_check(est, account, positions, limits):
    """Exposure after the order against equity (margin = leverage). Alpaca allows up to the account's multiplier
    (4× intraday, 2× overnight); trading.max_leverage can set a lower ceiling. Returns the summary note. Raises ValueError."""
    equity = float(account.get("equity") or 0)
    if equity <= 0:
        return ""
    gross = sum(abs(float(p.get("market_value") or 0)) for p in positions)
    lev = (gross + est) / equity
    cap = float(limits.get("max_leverage") or account.get("multiplier") or 1)
    if lev > cap:
        raise ValueError(f"exposure after the order would be {lev:.2f}× equity, over max_leverage {cap:g}×")
    return f" · leverage after: {lev:.2f}× equity" + (" (on margin)" if gross + est > float(account.get("cash") or 0) else "")


def is_occ(symbol):
    """AAPL261120C00230000: root, YYMMDD, C/P, strike × 1000 in 8 digits."""
    import re
    return bool(re.fullmatch(r"[A-Z.]{1,6}\d{6}[CP]\d{8}", symbol or ""))


def occ(underlying, expiration, kind, strike):
    """OCC option symbol: AAPL + 261120 + C + strike × 1000 in 8 digits."""
    y, m, d = str(expiration).split("-")
    return f"{underlying.upper()}{y[2:]}{m}{d}{'C' if kind.lower().startswith('c') else 'P'}{int(round(float(strike) * 1000)):08d}"


def parse_occ(symbol):
    """AAPL261120C00230000 → ("AAPL", "2026-11-20", "call", 230.0)."""
    root, rest = symbol[:-15], symbol[-15:]
    return root, f"20{rest[:2]}-{rest[2:4]}-{rest[4:6]}", "call" if rest[6] == "C" else "put", int(rest[7:]) / 1000


def coverage(symbol, positions):
    """How many contracts of `symbol` can be sold to open as the short leg of a spread: long contracts of the same underlying
    and type expiring on or after it (a vertical or calendar spread, risk defined), minus shorts they already cover."""
    root, exp, kind, _ = parse_occ(symbol)
    longs = shorts = 0.0
    for p in positions:
        s = p.get("symbol", "")
        if p.get("asset_class") not in (None, "us_option") or not is_occ(s) or s == symbol:
            continue
        r, e, k, _ = parse_occ(s)
        if r != root or k != kind:
            continue
        q = float(p.get("qty") or 0)
        if q > 0 and e >= exp:
            longs += q
        elif q < 0:
            shorts += -q
    return max(longs - shorts, 0.0)


def build_option(args, contract, quote, held, limits, covered=0.0):
    """One option leg. contract is Alpaca's contract, quote {bid, ask, last}, held = contracts held (+ long, − short),
    covered = how many may be sold to open against long contracts held (coverage()).
    Buy opens a long or closes a short; sell closes a long, or opens a short only as a spread leg (level 3: no naked short).
    Options trade DAY only, whole contracts, × the contract multiplier (100). Raises ValueError."""
    side, typ = args.get("side"), args.get("type", "limit")
    qty = args.get("qty")
    limit_price = _num(args, "limit_price")
    if side not in SIDES or typ not in ("market", "limit"):
        raise ValueError("side must be buy | sell, type market | limit")
    if qty is None or float(qty) <= 0 or float(qty) != int(float(qty)):
        raise ValueError("qty is the number of contracts, a whole number")
    qty = int(float(qty))
    if typ == "limit" and not limit_price:
        raise ValueError("limit orders need limit_price (per share; the contract costs × 100)")
    if not contract.get("tradable"):
        raise ValueError(f"{contract.get('symbol')} is not tradable")
    if side == "buy":
        intent = "buy_to_close" if held < 0 and qty <= -held else "buy_to_open"
    else:
        if held > 0 and qty <= held:
            intent = "sell_to_close"
        elif held <= 0 and qty <= covered:
            intent = "sell_to_open"
        else:
            raise ValueError(f"selling {qty} would open a naked short (covered by long contracts held: {covered:g}); the account's options "
                             "level allows a short only as a spread leg against a long call/put of the same underlying expiring on or after it")
    mult = float(contract.get("multiplier") or 100)
    ref = limit_price or (quote.get("ask") if side == "buy" else quote.get("bid")) or quote.get("last")
    if not ref:
        raise ValueError(f"no quote for {contract['symbol']}; use a limit order")
    est = qty * mult * float(ref)
    cap = float(limits.get("max_order_usd") or 0)
    if cap and intent.endswith("open") and est > cap:
        raise ValueError(f"estimated {est:,.2f} USD is over max_order_usd {cap:,.0f}")
    body = {"symbol": contract["symbol"], "side": side, "type": typ, "qty": str(qty), "time_in_force": "day", "position_intent": intent}
    if limit_price:
        body["limit_price"] = px(limit_price)
    q = f"bid {quote.get('bid') or '-'} / ask {quote.get('ask') or '-'}"
    at = f"limit {px(limit_price)}" if limit_price else f"market ({q})"
    summary = (f"PAPER OPTION {intent.upper().replace('_', ' ')} {qty} × {contract.get('name') or contract['symbol']} ({contract['symbol']}) "
               f"at {at}, DAY, est. {est:,.2f} USD ({qty} × {mult:g} × {float(ref):.2f})")
    if intent == "buy_to_open":
        summary += f" · max loss = premium {est:,.2f} USD"
    if intent == "sell_to_open":
        summary += " · short leg of a spread, covered by your long contracts (premium received; keep both legs until you close the spread)"
    return body, summary, est


def build_exit(args, position, price):
    """Protect an open position: take profit and stop loss together (OCO), only one of them, or a trailing stop.
    position is Alpaca's position (qty, side). Closes at most the position, never opens a new one. Raises ValueError."""
    if not position:
        raise ValueError(f"no open position in {str(args.get('symbol', '')).upper()}; use propose_order for a new trade")
    sym = position["symbol"]
    held = abs(float(position["qty"]))
    long = position.get("side", "long") == "long" and float(position["qty"]) > 0
    side = "sell" if long else "buy"
    qty = float(args.get("qty") or held)
    tif = args.get("time_in_force", "gtc")
    tp, sl, sl_limit = _num(args, "take_profit_price"), _num(args, "stop_loss_price"), _num(args, "stop_loss_limit_price")
    trail_pct, trail_px = _num(args, "trail_percent"), _num(args, "trail_price")
    if tif not in TIFS:
        raise ValueError(f"time_in_force must be {TIFS}")
    if qty <= 0 or qty > held:
        raise ValueError(f"qty must be between 0 and the position's {held:g} shares")
    trailing = trail_pct is not None or trail_px is not None
    if trailing and (tp or sl):
        raise ValueError("give either a trailing stop or take profit / stop loss, not both")
    if not trailing and not (tp or sl):
        raise ValueError("give take_profit_price and/or stop_loss_price, or trail_percent / trail_price")
    if trail_pct is not None and trail_px is not None:
        raise ValueError("give one of trail_percent or trail_price")
    q = str(int(qty)) if qty == int(qty) else str(qty)
    body = {"symbol": sym, "side": side, "qty": q, "time_in_force": tif}
    what = f"PAPER EXIT {'long' if long else 'short'} {q} {sym}"
    # the exit's direction is the opposite of the position: for a long, profit is above the price, the stop below
    entry_side = "buy" if long else "sell"
    if trailing:
        body.update({"type": "trailing_stop", **({"trail_percent": str(trail_pct)} if trail_pct else {"trail_price": px(trail_px)})})
        return body, f"{what}: trailing stop {f'{trail_pct:g} %' if trail_pct else px(trail_px) + ' USD'}, {tif.upper()}"
    if tp and sl:
        body.update({"type": "limit", "order_class": "oco"})
        legs = _legs(body, entry_side, price, tp, sl, sl_limit, "last price")
        return body, f"{what}: {legs} (OCO, one cancels the other), {tif.upper()}"
    _check_side(entry_side, price, tp, sl, "last price")
    if tp:
        body.update({"type": "limit", "limit_price": px(tp)})
        return body, f"{what}: take profit at limit {px(tp)}, {tif.upper()}"
    if sl_limit is not None:
        body.update({"type": "stop_limit", "stop_price": px(sl), "limit_price": px(sl_limit)})
        return body, f"{what}: stop loss {px(sl)} (limit {px(sl_limit)}), {tif.upper()}"
    body.update({"type": "stop", "stop_price": px(sl)})
    return body, f"{what}: stop loss {px(sl)}, {tif.upper()}"


REPLACEABLE = ("qty", "limit_price", "stop_price", "trail", "time_in_force")


def build_replace(args, order):
    """Change an open order (move a stop loss or take profit, qty, trail). order is Alpaca's order. Raises ValueError."""
    if not order or order.get("status") not in ("new", "accepted", "held", "partially_filled", "pending_new"):
        raise ValueError(f"order {args.get('order_id')} is not open ({(order or {}).get('status')})")
    body, changes = {}, []
    for key, alpaca_key in (("qty", "qty"), ("limit_price", "limit_price"), ("stop_price", "stop_price"), ("trail", "trail")):
        v = _num(args, key)
        if v is not None:
            body[alpaca_key] = str(int(v)) if key == "qty" and v == int(v) else (str(v) if key in ("qty", "trail") else px(v))
            old = (order.get("trail_percent") or order.get("trail_price")) if key == "trail" else order.get(alpaca_key)
            changes.append(f"{key} {old or '-'} → {body[alpaca_key]}")
    if args.get("time_in_force"):
        if args["time_in_force"] not in TIFS:
            raise ValueError(f"time_in_force must be {TIFS}")
        body["time_in_force"] = args["time_in_force"]
        changes.append(f"time_in_force {order.get('time_in_force')} → {body['time_in_force']}")
    if not body:
        raise ValueError(f"nothing to change; give one of {REPLACEABLE}")
    if "stop_price" in body and order.get("type") not in ("stop", "stop_limit"):
        raise ValueError(f"order is {order.get('type')}, it has no stop_price")
    if "limit_price" in body and order.get("type") not in ("limit", "stop_limit"):
        raise ValueError(f"order is {order.get('type')}, it has no limit_price")
    if "trail" in body and order.get("type") != "trailing_stop":
        raise ValueError("trail only changes a trailing_stop order")
    desc = f"{order.get('side', '').upper()} {order.get('qty')} {order.get('symbol')} {order.get('type')}"
    return body, f"PAPER CHANGE {desc} ({str(order.get('id', ''))[:8]}): " + ", ".join(changes)


def _load():
    try:
        with open(PROPOSALS) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def _save(p):
    os.makedirs(os.path.dirname(PROPOSALS), exist_ok=True)
    with open(PROPOSALS, "w") as f:
        json.dump(p, f)


def propose(body, summary, minutes, replace_id=None):
    """Keep a proposal until committed; replace_id makes it a change of that open order instead of a new one."""
    now = time.time()
    p = {k: v for k, v in _load().items() if v["expires"] > now}
    pid = "prop_" + secrets.token_hex(4)
    p[pid] = {"body": body, "summary": summary, "expires": now + minutes * 60, **({"replace_id": replace_id} if replace_id else {})}
    _save(p)
    return pid


def take(pid):
    """Return and remove a live proposal. Raises ValueError if unknown or expired."""
    p = _load()
    prop = p.pop(pid, None)
    _save(p)
    if not prop:
        raise ValueError(f"no proposal {pid}; propose the order again")
    if prop["expires"] < time.time():
        raise ValueError(f"{pid} expired; propose the order again")
    return prop


def log(event):
    os.makedirs(os.path.dirname(ORDER_LOG), exist_ok=True)
    with open(ORDER_LOG, "a") as f:
        f.write(json.dumps(dict(event, at=time.strftime("%Y-%m-%dT%H:%M:%S"))) + "\n")
