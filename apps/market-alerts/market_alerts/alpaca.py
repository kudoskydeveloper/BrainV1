"""Minimal Alpaca client (paper trading + market data), standard library only."""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

KEYS_FILE = os.path.expanduser("~/.config/market-alerts/keys.env")
TRADING = "https://paper-api.alpaca.markets"   # paper only, never the live endpoint
DATA = "https://data.alpaca.markets"


def load_keys(path=KEYS_FILE):
    keys = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                keys[k.strip()] = v.strip()
    if not keys.get("ALPACA_KEY_ID") or not keys.get("ALPACA_SECRET_KEY"):
        raise SystemExit(f"Alpaca keys missing in {path}")
    return keys


class Alpaca:
    def __init__(self, keys):
        self.headers = {"APCA-API-KEY-ID": keys["ALPACA_KEY_ID"],
                        "APCA-API-SECRET-KEY": keys["ALPACA_SECRET_KEY"],
                        "Accept": "application/json"}

    def _call(self, method, base, path, params=None, body=None):
        q = {k: v for k, v in (params or {}).items() if v is not None}
        url = f"{base}{path}" + ("?" + urllib.parse.urlencode(q) if q else "")
        data = json.dumps(body).encode() if body is not None else None
        headers = dict(self.headers, **({"Content-Type": "application/json"} if data else {}))
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raise AlpacaError(f"Alpaca {e.code} on {method} {path}: {e.read()[:300].decode(errors='replace')}")

    def _get(self, base, path, **params):
        return self._call("GET", base, path, params)

    def clock(self):
        return self._get(TRADING, "/v2/clock")

    def account(self):
        return self._get(TRADING, "/v2/account")

    def positions(self):
        return self._get(TRADING, "/v2/positions")

    def orders(self, after=None):
        return self._get(TRADING, "/v2/orders", status="closed", after=after, limit=500, direction="asc")

    def snapshots(self, symbols):
        # free plans get the IEX feed
        return self._get(DATA, "/v2/stocks/snapshots", symbols=",".join(symbols), feed="iex")

    def news(self, symbols, limit=10):
        return self._get(DATA, "/v1beta1/news", symbols=",".join(symbols), limit=limit).get("news", [])

    def list_orders(self, status="open", limit=50):
        # nested: a bracket's take-profit and stop-loss legs come inside their parent order
        return self._get(TRADING, "/v2/orders", status=status, limit=limit, direction="desc", nested="true")

    def order(self, order_id):
        return self._get(TRADING, f"/v2/orders/{urllib.parse.quote(order_id)}", nested="true")

    def position(self, symbol):
        """The open position in symbol, or None."""
        try:
            return self._get(TRADING, f"/v2/positions/{urllib.parse.quote(symbol)}")
        except AlpacaError as e:
            if " 404 " in str(e):
                return None
            raise

    def replace_order(self, order_id, changes):
        return self._call("PATCH", TRADING, f"/v2/orders/{urllib.parse.quote(order_id)}", body=changes)

    def place_order(self, order):
        return self._call("POST", TRADING, "/v2/orders", body=order)

    def cancel_order(self, order_id):
        return self._call("DELETE", TRADING, f"/v2/orders/{urllib.parse.quote(order_id)}")

    def option_contracts(self, underlying, **filters):
        """Option contracts of an underlying (expiration_date, expiration_date_gte/lte, type, strike_price_gte/lte, limit)."""
        return self._get(TRADING, "/v2/options/contracts", underlying_symbols=underlying, **filters).get("option_contracts", [])

    def bars(self, symbol, start, timeframe="1Day"):
        """Daily bars (IEX feed on the free plan), oldest first, all pages."""
        out, token = [], None
        while True:
            r = self._get(DATA, f"/v2/stocks/{urllib.parse.quote(symbol)}/bars", timeframe=timeframe, start=start, feed="iex",
                          adjustment="all", limit=10000, page_token=token)
            out += r.get("bars") or []
            token = r.get("next_page_token")
            if not token:
                return out

    def option_contract(self, symbol):
        return self._get(TRADING, f"/v2/options/contracts/{urllib.parse.quote(symbol)}")

    def option_snapshots(self, underlying, **filters):
        """Quotes, greeks and implied volatility for an underlying's contracts; the free plan gets the indicative feed."""
        return self._get(DATA, f"/v1beta1/options/snapshots/{urllib.parse.quote(underlying)}", feed="indicative", **filters).get("snapshots", {})

    def asset(self, symbol):
        return self._get(TRADING, f"/v2/assets/{urllib.parse.quote(symbol)}")


class AlpacaError(Exception):
    pass
