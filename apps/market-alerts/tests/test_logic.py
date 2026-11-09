import unittest

from market_alerts import logic

SNAP = {
    "AAPL": {"prevDailyBar": {"c": 200.0}, "latestTrade": {"p": 208.0}},
    "MSFT": {"prevDailyBar": {"c": 400.0}, "latestTrade": {"p": 398.0}},
    "NVDA": {"prevDailyBar": {"c": 100.0}, "dailyBar": {"c": 96.0}},
    "BAD": {"prevDailyBar": {}},
}
CFG = {"move_alert_pct": 3.0, "levels": [{"symbol": "MSFT", "below": 399, "above": 0}]}


class Logic(unittest.TestCase):
    def test_moves(self):
        m = logic.moves(SNAP)
        self.assertAlmostEqual(m["AAPL"]["pct"], 4.0)
        self.assertAlmostEqual(m["NVDA"]["pct"], -4.0)   # falls back to the daily bar
        self.assertNotIn("BAD", m)

    def test_alerts_fire_once(self):
        m = logic.moves(SNAP)
        first = logic.alerts(m, CFG, set())
        self.assertEqual(sorted(k for k, _ in first), ["below:MSFT:399", "move:AAPL:up", "move:NVDA:down"])
        self.assertEqual(logic.alerts(m, CFG, {k for k, _ in first}), [])

    def test_brief(self):
        acct = {"equity": "101000", "last_equity": "100000", "cash": "50000"}
        pos = [{"symbol": "AAPL", "qty": "10", "current_price": "208", "unrealized_pl": "80", "unrealized_plpc": "0.04"}]
        news = [{"id": 1, "headline": "Apple news", "url": "https://x", "symbols": ["AAPL"]}]
        md = logic.brief("2026-11-03", logic.moves(SNAP), acct, pos, news, CFG)
        self.assertIn("+1,000.00", md)
        self.assertIn("| AAPL | 208.00 | 200.00 | +4.00% ⚠️ |", md)
        self.assertIn("[Apple news](https://x)", md)

    def test_pick_news(self):
        items = [{"id": i, "headline": str(i), "symbols": ["AAPL"]} for i in range(5)]
        self.assertEqual(len(logic.pick_news(items, {"AAPL"}, 2)), 2)


if __name__ == "__main__":
    unittest.main()
