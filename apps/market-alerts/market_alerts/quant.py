"""Trading math, computed instead of guessed: Black-Scholes prices and greeks, implied volatility, payoff of option
strategies, position sizing and simple daily backtests. Standard library only; no network here (the server feeds prices)."""
import math
from datetime import date

YEAR = 365.0


def _n(x):
    return math.exp(-x * x / 2) / math.sqrt(2 * math.pi)


def _cdf(x):
    return 0.5 * (1 + math.erf(x / math.sqrt(2)))


def years(expiration, today=None):
    """Time to expiration in years (at least one hour, so expiry day still prices)."""
    d = (date.fromisoformat(str(expiration)[:10]) - (today or date.today())).days
    return max(d, 1 / 24) / YEAR


def bs(kind, s, k, t, iv, r=0.04, q=0.0):
    """Black-Scholes(-Merton) price and greeks per share. kind call | put, t in years, iv and r as decimals.
    delta per 1 USD, gamma per 1 USD, theta per calendar day, vega and rho per 1 percentage point."""
    if t <= 0 or iv <= 0:
        intrinsic = max(s - k, 0) if kind == "call" else max(k - s, 0)
        return {"price": intrinsic, "delta": (1.0 if s > k else 0.0) if kind == "call" else (-1.0 if s < k else 0.0),
                "gamma": 0.0, "theta": 0.0, "vega": 0.0, "rho": 0.0}
    st = iv * math.sqrt(t)
    d1 = (math.log(s / k) + (r - q + iv * iv / 2) * t) / st
    d2 = d1 - st
    dq, dr = math.exp(-q * t), math.exp(-r * t)
    if kind == "call":
        price = s * dq * _cdf(d1) - k * dr * _cdf(d2)
        delta = dq * _cdf(d1)
        theta = -s * dq * _n(d1) * iv / (2 * math.sqrt(t)) - r * k * dr * _cdf(d2) + q * s * dq * _cdf(d1)
        rho = k * t * dr * _cdf(d2)
    else:
        price = k * dr * _cdf(-d2) - s * dq * _cdf(-d1)
        delta = -dq * _cdf(-d1)
        theta = -s * dq * _n(d1) * iv / (2 * math.sqrt(t)) + r * k * dr * _cdf(-d2) - q * s * dq * _cdf(-d1)
        rho = -k * t * dr * _cdf(-d2)
    return {"price": price, "delta": delta, "gamma": dq * _n(d1) / (s * st), "theta": theta / YEAR,
            "vega": s * dq * _n(d1) * math.sqrt(t) / 100, "rho": rho / 100}


def implied_vol(kind, price, s, k, t, r=0.04, q=0.0):
    """The volatility at which Black-Scholes gives `price` (bisection), or None when the price is outside what any vol gives."""
    lo, hi = 1e-4, 5.0
    if not (bs(kind, s, k, t, lo, r, q)["price"] - 1e-9 <= price <= bs(kind, s, k, t, hi, r, q)["price"]):
        return None
    for _ in range(100):
        mid = (lo + hi) / 2
        if bs(kind, s, k, t, mid, r, q)["price"] < price:
            lo = mid
        else:
            hi = mid
    return (lo + hi) / 2


def prob_above(s, x, t, iv, r=0.04):
    """Risk-neutral probability the underlying ends above x at t (lognormal)."""
    if t <= 0 or iv <= 0:
        return 1.0 if s > x else 0.0
    return _cdf((math.log(s / x) + (r - iv * iv / 2) * t) / (iv * math.sqrt(t)))


def leg_value(leg, s, t_left):
    """Value per share of one leg at underlying price s with t_left years to its expiration (stock legs: s)."""
    if leg["kind"] == "stock":
        return s
    if t_left <= 0:
        return max(s - leg["strike"], 0) if leg["kind"] == "call" else max(leg["strike"] - s, 0)
    return bs(leg["kind"], s, leg["strike"], t_left, leg["iv"], leg.get("r", 0.04))["price"]


def payoff(legs, spot, iv=None, today=None, points=41):
    """P/L of a strategy. legs: [{kind call|put|stock, strike, expiration, qty (+ long, − short), price (paid per share), iv}].
    Options count × 100 (multiplier). Evaluated at the first expiration (later legs keep their time value).
    Returns the P/L table over ±40 % around spot, break-evens, max profit / loss (None = unlimited) and the probability of
    finishing with a profit at that date, using each leg's iv (or iv)."""
    opts = [l for l in legs if l["kind"] != "stock"]
    for l in opts:
        l.setdefault("iv", iv or 0.4)
        l["t"] = years(l["expiration"], today)
    t_end = min((l["t"] for l in opts), default=0.0)
    mult = lambda l: 1 if l["kind"] == "stock" else 100   # noqa: E731
    cost = sum(l["qty"] * l["price"] * mult(l) for l in legs)

    def pl(s):
        return sum(l["qty"] * leg_value(l, s, (l["t"] - t_end) if l["kind"] != "stock" else 0) * mult(l) for l in legs) - cost

    lo, hi = spot * 0.6, spot * 1.4
    grid = sorted({round(lo + (hi - lo) * i / (points - 1), 2) for i in range(points)} | {l["strike"] for l in opts} | {round(spot, 2)})
    table = [(s, pl(s)) for s in grid]
    # break-evens: sign changes on a fine grid
    fine = [lo + (hi - lo) * i / 2000 for i in range(2001)]
    be = []
    for a, b in zip(fine, fine[1:]):
        pa, pb = pl(a), pl(b)
        if pa == 0 or (pa < 0) != (pb < 0):
            be.append(round(a + (b - a) * (abs(pa) / (abs(pa) + abs(pb) or 1)), 2))
    # far tails decide whether profit / loss is bounded: net calls (and stock) beyond the highest strike
    up_slope = sum(l["qty"] * mult(l) for l in legs if l["kind"] in ("call", "stock"))
    down_slope = -sum(l["qty"] * mult(l) for l in legs if l["kind"] in ("put", "stock"))
    edge = [pl(0.01), pl(hi * 3)]
    max_profit = None if up_slope > 0 or down_slope > 0 else max([v for _, v in table] + edge)
    max_loss = None if up_slope < 0 else min([v for _, v in table] + edge)
    # probability of profit: integrate over the lognormal at t_end with the average iv
    sig = (sum(l["iv"] for l in opts) / len(opts)) if opts else (iv or 0.4)
    pop = 0.0
    if t_end > 0:
        n = 400
        for i in range(n):
            a, b = 0.01 + hi * 3 * i / n, 0.01 + hi * 3 * (i + 1) / n
            p = prob_above(spot, a, t_end, sig) - prob_above(spot, b, t_end, sig)
            if pl((a + b) / 2) > 0:
                pop += p
    return {"net_cost": round(cost, 2), "at_date_years": round(t_end, 4), "break_evens": be,
            "max_profit": None if max_profit is None else round(max_profit, 2),
            "max_loss": None if max_loss is None else round(max_loss, 2),
            "prob_profit": round(pop, 3) if t_end > 0 else None,
            "table": [{"price": round(s, 2), "pl": round(v, 2)} for s, v in table]}


def position_size(equity, entry, stop, risk_pct=None, risk_usd=None, max_leverage=None, cash=None):
    """Shares so that hitting the stop loses at most risk_usd (or risk_pct % of equity). Long when stop < entry, short above."""
    if entry <= 0 or stop <= 0 or entry == stop:
        raise ValueError("entry and stop must be positive and different")
    risk = risk_usd if risk_usd else equity * (risk_pct or 1) / 100
    per_share = abs(entry - stop)
    qty = math.floor(risk / per_share)
    notional = qty * entry
    out = {"side": "buy (long)" if stop < entry else "sell (short)", "qty": qty, "risk_per_share": round(per_share, 4),
           "risk_usd": round(qty * per_share, 2), "notional_usd": round(notional, 2),
           "pct_of_equity": round(notional / equity * 100, 1) if equity else None,
           "stop_distance_pct": round(per_share / entry * 100, 2)}
    if max_leverage and equity and notional > equity * max_leverage:
        capped = math.floor(equity * max_leverage / entry)
        out.update(qty_capped_by_leverage=capped, note=f"{qty} shares would be {notional / equity:.2f}× equity, over {max_leverage:g}×")
    if cash is not None and notional > cash:
        out["on_margin_usd"] = round(notional - cash, 2)
    return out


def backtest(bars, strategy="buy_hold", fast=20, slow=50, lookback=20, cost_bps=5):
    """Daily backtest on closes. bars: [{t, c}] oldest first. strategy buy_hold | sma_cross (long while SMA fast > slow) |
    breakout (long after a close above the last `lookback` highs of closes, out below the last `lookback` lows).
    Returns total and yearly return, max drawdown, Sharpe (daily, no risk-free), trades, time in market, vs buy and hold."""
    closes = [float(b["c"]) for b in bars]
    if len(closes) < max(slow, lookback) + 2:
        raise ValueError(f"need more history: {len(closes)} days")
    pos = [0] * len(closes)
    for i in range(1, len(closes)):
        if strategy == "buy_hold":
            pos[i] = 1
        elif strategy == "sma_cross":
            if i >= slow:
                pos[i] = 1 if sum(closes[i - fast:i]) / fast > sum(closes[i - slow:i]) / slow else 0
        elif strategy == "breakout":
            if i > lookback:
                win = closes[i - lookback - 1:i - 1]
                pos[i] = 1 if closes[i - 1] > max(win) else 0 if closes[i - 1] < min(win) else pos[i - 1]
        else:
            raise ValueError("strategy: buy_hold | sma_cross | breakout")
    eq, peak, mdd, rets, trades = 1.0, 1.0, 0.0, [], 0
    for i in range(1, len(closes)):
        r = pos[i] * (closes[i] / closes[i - 1] - 1)
        if pos[i] != pos[i - 1]:
            trades += 1
            r -= cost_bps / 10000
        eq *= 1 + r
        rets.append(r)
        peak = max(peak, eq)
        mdd = min(mdd, eq / peak - 1)
    days = len(rets)
    mean = sum(rets) / days
    sd = math.sqrt(sum((x - mean) ** 2 for x in rets) / max(days - 1, 1))
    bh = closes[-1] / closes[0] - 1
    return {"strategy": strategy, "days": days, "total_return_pct": round((eq - 1) * 100, 2),
            "yearly_return_pct": round((eq ** (252 / days) - 1) * 100, 2), "max_drawdown_pct": round(mdd * 100, 2),
            "sharpe": round(mean / sd * math.sqrt(252), 2) if sd else None, "trades": trades,
            "time_in_market_pct": round(sum(pos[1:]) / days * 100, 1), "buy_hold_return_pct": round(bh * 100, 2),
            "note": "Past results on daily closes with a simple cost per trade; not a forecast."}
