"""Next earnings date per symbol from Nasdaq's public analyst API (Zacks estimates), standard library only."""
import json
import re
import urllib.request
from datetime import datetime

URL = "https://api.nasdaq.com/api/analyst/{}/earnings-date"


def next_earnings(symbol):
    """{symbol, date YYYY-MM-DD, time before open | after close | ?, quarter, eps_forecast, confirmed: False (an estimate)}."""
    req = urllib.request.Request(URL.format(symbol.upper()), headers={"User-Agent": "Mozilla/5.0", "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        d = (json.load(r) or {}).get("data") or {}
    text = " ".join(str(d.get(k) or "") for k in ("announcement", "reportText"))
    m = re.search(r"(\d{1,2}/\d{1,2}/\d{4})", text) or re.search(r"([A-Z][a-z]{2} \d{1,2}, \d{4})", text)
    if not m:
        return {"symbol": symbol.upper(), "date": None, "note": "no upcoming date published"}
    raw = m.group(1)
    day = datetime.strptime(raw, "%m/%d/%Y" if "/" in raw else "%b %d, %Y").date().isoformat()
    when = "after close" if "after market close" in text else "before open" if "before market open" in text else "?"
    eps = re.search(r"consensus EPS forecast for the quarter is (\$-?\d+(?:\.\d+)?)", text)
    q = re.search(r"fiscal Quarter ending (\w+ \d{4})", text)
    return {"symbol": symbol.upper(), "date": day, "time": when, "fiscal_quarter": q and q.group(1), "eps_forecast": eps and eps.group(1),
            "estimated": "expected*" in text or "*" in str(d.get("announcement")), "source": "Nasdaq (Zacks)"}
