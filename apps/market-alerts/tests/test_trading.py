import unittest

from market_alerts import trading

LIM = {"max_order_usd": 5000, "allowed_symbols": []}


class Build(unittest.TestCase):
    def test_market_qty(self):
        body, summary, est = trading.build({"symbol": "msft", "side": "buy", "qty": 2}, 500.0, LIM)
        self.assertEqual(body, {"symbol": "MSFT", "side": "buy", "type": "market", "time_in_force": "day", "qty": "2"})
        self.assertEqual(est, 1000.0)
        self.assertTrue(summary.startswith("PAPER BUY 2 shares MSFT"))

    def test_limit_uses_limit_price_for_estimate(self):
        body, _, est = trading.build({"symbol": "SPY", "side": "sell", "qty": 1, "type": "limit", "limit_price": 700}, 750, LIM)
        self.assertEqual((body["limit_price"], est), ("700.00", 700.0))

    def test_rejections(self):
        bad = [
            {"symbol": "MSFT", "side": "buy", "qty": 20},                        # 10,000 USD over the cap
            {"symbol": "MSFT", "side": "hold", "qty": 1},                        # bad side
            {"symbol": "MSFT", "side": "buy"},                                   # no size
            {"symbol": "MSFT", "side": "buy", "qty": 1, "notional_usd": 100},    # both sizes
            {"symbol": "MSFT", "side": "buy", "qty": 1, "type": "limit"},        # limit without price
            {"symbol": "MSFT", "side": "buy", "notional_usd": 100, "type": "limit", "limit_price": 5},
        ]
        for a in bad:
            with self.assertRaises(ValueError, msg=a):
                trading.build(a, 500.0, LIM)

    def test_allowlist(self):
        with self.assertRaises(ValueError):
            trading.build({"symbol": "TSLA", "side": "buy", "qty": 1}, 400, dict(LIM, allowed_symbols=["SPY"]))


class Stops(unittest.TestCase):
    def test_stop_and_stop_limit(self):
        body, summary, est = trading.build({"symbol": "AAPL", "side": "sell", "qty": 3, "type": "stop", "stop_price": 330}, 350, LIM)
        self.assertEqual((body["type"], body["stop_price"], est), ("stop", "330.00", 990.0))
        body, _, _ = trading.build({"symbol": "AAPL", "side": "buy", "qty": 1, "type": "stop_limit", "stop_price": 360, "limit_price": 361}, 350, LIM)
        self.assertEqual((body["stop_price"], body["limit_price"]), ("360.00", "361.00"))
        with self.assertRaises(ValueError):   # a sell stop above the market would fire at once
            trading.build({"symbol": "AAPL", "side": "sell", "qty": 1, "type": "stop", "stop_price": 360}, 350, LIM)

    def test_trailing(self):
        body, summary, _ = trading.build({"symbol": "NVDA", "side": "sell", "qty": 2, "type": "trailing_stop", "trail_percent": 5}, 200, LIM)
        self.assertEqual((body["type"], body["trail_percent"]), ("trailing_stop", "5.0"))
        self.assertIn("trailing stop 5 %", summary)
        with self.assertRaises(ValueError):
            trading.build({"symbol": "NVDA", "side": "sell", "qty": 2, "type": "trailing_stop"}, 200, LIM)

    def test_bracket_and_oto(self):
        body, summary, _ = trading.build({"symbol": "MSFT", "side": "buy", "qty": 2, "type": "limit", "limit_price": 500,
                                          "take_profit_price": 550, "stop_loss_price": 480, "time_in_force": "gtc"}, 510, LIM)
        self.assertEqual(body["order_class"], "bracket")
        self.assertEqual(body["take_profit"], {"limit_price": "550.00"})
        self.assertEqual(body["stop_loss"], {"stop_price": "480.00"})
        self.assertIn("BRACKET", summary)
        body, _, _ = trading.build({"symbol": "MSFT", "side": "buy", "qty": 2, "stop_loss_price": 480, "stop_loss_limit_price": 478}, 500, LIM)
        self.assertEqual((body["order_class"], body["stop_loss"]), ("oto", {"stop_price": "480.00", "limit_price": "478.00"}))

    def test_legs_default_to_gtc_and_day_warns(self):
        body, summary, _ = trading.build({"symbol": "MSFT", "side": "buy", "qty": 2, "take_profit_price": 550, "stop_loss_price": 480}, 500, LIM)
        self.assertEqual(body["time_in_force"], "gtc")
        self.assertNotIn("⚠️", summary)
        body, summary, _ = trading.build({"symbol": "MSFT", "side": "buy", "qty": 2, "stop_loss_price": 480, "time_in_force": "day"}, 500, LIM)
        self.assertEqual(body["time_in_force"], "day")
        self.assertIn("⚠️ DAY", summary)
        body, _, _ = trading.build({"symbol": "MSFT", "side": "buy", "qty": 2}, 500, LIM)
        self.assertEqual(body["time_in_force"], "day")   # plain orders keep DAY

    def test_bracket_rejections(self):
        bad = [
            {"take_profit_price": 490, "stop_loss_price": 480},   # long take profit below entry
            {"take_profit_price": 550, "stop_loss_price": 510},   # long stop above entry
            {"stop_loss_limit_price": 470},                       # limit without stop
            {"stop_loss_price": 480, "stop_loss_limit_price": 485},   # stop-limit above the stop for a long
            {"take_profit_price": 550, "qty": 1.5},               # fractional bracket
        ]
        for extra in bad:
            a = dict({"symbol": "MSFT", "side": "buy", "qty": 2}, **extra)
            with self.assertRaises(ValueError, msg=extra):
                trading.build(a, 500, LIM)
        with self.assertRaises(ValueError):   # short: take profit must be below
            trading.build({"symbol": "MSFT", "side": "sell", "qty": 2, "take_profit_price": 520}, 500, LIM)


class Exits(unittest.TestCase):
    LONG = {"symbol": "AAPL", "qty": "10", "side": "long"}

    def test_oco_for_long(self):
        body, summary = trading.build_exit({"symbol": "AAPL", "take_profit_price": 380, "stop_loss_price": 330}, self.LONG, 350)
        self.assertEqual(body, {"symbol": "AAPL", "side": "sell", "qty": "10", "time_in_force": "gtc", "type": "limit",
                                "order_class": "oco", "take_profit": {"limit_price": "380.00"}, "stop_loss": {"stop_price": "330.00"}})
        self.assertIn("OCO", summary)

    def test_single_legs_and_trailing(self):
        body, _ = trading.build_exit({"symbol": "AAPL", "stop_loss_price": 330, "qty": 4}, self.LONG, 350)
        self.assertEqual((body["type"], body["stop_price"], body["qty"]), ("stop", "330.00", "4"))
        body, _ = trading.build_exit({"symbol": "AAPL", "take_profit_price": 380}, self.LONG, 350)
        self.assertEqual((body["type"], body["limit_price"]), ("limit", "380.00"))
        body, _ = trading.build_exit({"symbol": "AAPL", "trail_price": 10}, self.LONG, 350)
        self.assertEqual((body["type"], body["trail_price"]), ("trailing_stop", "10.00"))

    def test_short_position_buys_back(self):
        body, _ = trading.build_exit({"symbol": "TSLA", "take_profit_price": 350, "stop_loss_price": 420},
                                     {"symbol": "TSLA", "qty": "-5", "side": "short"}, 390)
        self.assertEqual((body["side"], body["qty"]), ("buy", "5"))

    def test_exit_rejections(self):
        for a in ({"symbol": "AAPL"},                                              # nothing to set
                  {"symbol": "AAPL", "stop_loss_price": 360},                      # stop above the price for a long
                  {"symbol": "AAPL", "stop_loss_price": 330, "qty": 11},           # more than held
                  {"symbol": "AAPL", "stop_loss_price": 330, "trail_percent": 3}):  # both styles
            with self.assertRaises(ValueError, msg=a):
                trading.build_exit(a, self.LONG, 350)
        with self.assertRaises(ValueError):
            trading.build_exit({"symbol": "AAPL", "stop_loss_price": 330}, None, 350)   # no position


class Replace(unittest.TestCase):
    STOP = {"id": "abcdef1234", "status": "new", "type": "stop", "side": "sell", "qty": "10", "symbol": "AAPL", "stop_price": "330"}

    def test_move_stop(self):
        body, summary = trading.build_replace({"order_id": "abcdef1234", "stop_price": 340}, self.STOP)
        self.assertEqual(body, {"stop_price": "340.00"})
        self.assertIn("stop_price 330 → 340.00", summary)

    def test_replace_rejections(self):
        for a, o in (({"stop_price": 340}, dict(self.STOP, status="filled")),
                     ({}, self.STOP),
                     ({"limit_price": 400}, self.STOP),
                     ({"trail": 2}, self.STOP)):
            with self.assertRaises(ValueError, msg=a):
                trading.build_replace(dict(a, order_id="abcdef1234"), o)


if __name__ == "__main__":
    unittest.main()


class ShortsLeverageOptions(unittest.TestCase):
    ASSET = {"shortable": True, "easy_to_borrow": True}

    def test_short_needs_shortable_whole_shares(self):
        body = {"symbol": "TSLA", "side": "sell", "qty": "2"}
        self.assertIn("SHORT", trading.short_check(body, None, self.ASSET))
        self.assertEqual(trading.short_check(body, {"qty": "5"}, self.ASSET), "")       # selling shares held
        with self.assertRaises(ValueError):
            trading.short_check(body, None, {"shortable": True, "easy_to_borrow": False})
        with self.assertRaises(ValueError):
            trading.short_check(dict(body, qty="1.5"), None, self.ASSET)

    def test_leverage(self):
        acct = {"equity": "10000", "cash": "10000", "multiplier": "2"}
        self.assertIn("1.50×", trading.leverage_check(5000, acct, [{"market_value": "10000"}], {}))
        with self.assertRaises(ValueError):
            trading.leverage_check(15000, acct, [{"market_value": "10000"}], {})
        with self.assertRaises(ValueError):
            trading.leverage_check(5000, acct, [{"market_value": "10000"}], {"max_leverage": 1.2})

    def test_occ(self):
        self.assertEqual(trading.occ("aapl", "2026-11-20", "call", 230), "AAPL261120C00230000")
        self.assertEqual(trading.occ("SPY", "2026-12-18", "put", 512.5), "SPY261218P00512500")

    def test_option_intents(self):
        k = {"symbol": "AAPL261120C00230000", "tradable": True, "multiplier": "100"}
        q = {"bid": 1.0, "ask": 1.2, "last": 1.1}
        body, summary, est = trading.build_option({"side": "buy", "qty": 2, "limit_price": 1.2}, k, q, 0, LIM)
        self.assertEqual((body["position_intent"], body["time_in_force"], est), ("buy_to_open", "day", 240.0))
        body, _, _ = trading.build_option({"side": "sell", "qty": 1, "limit_price": 1}, k, q, 2, LIM)
        self.assertEqual(body["position_intent"], "sell_to_close")
        with self.assertRaises(ValueError):            # naked short
            trading.build_option({"side": "sell", "qty": 1, "limit_price": 1}, k, q, 0, LIM)
        pos = [{"symbol": "AAPL261120C00220000", "qty": "2", "asset_class": "us_option"}]
        cov = trading.coverage("AAPL261120C00230000", pos)
        self.assertEqual(cov, 2)
        body, summary, _ = trading.build_option({"side": "sell", "qty": 2, "limit_price": 1}, k, q, 0, LIM, covered=cov)
        self.assertEqual(body["position_intent"], "sell_to_open")
        self.assertEqual(trading.coverage("AAPL261218C00230000", pos), 0)    # long expires before the short
        self.assertEqual(trading.coverage("AAPL261120P00230000", pos), 0)    # different type
        with self.assertRaises(ValueError):            # fractional contracts
            trading.build_option({"side": "buy", "qty": 1.5, "limit_price": 1}, k, q, 0, LIM)


from market_alerts import quant


class Quant(unittest.TestCase):
    def test_black_scholes_textbook(self):
        # Hull: S=42, K=40, r=10 %, sigma=20 %, T=0.5 → call 4.76, put 0.81
        c, p = quant.bs("call", 42, 40, 0.5, 0.2, 0.1), quant.bs("put", 42, 40, 0.5, 0.2, 0.1)
        self.assertAlmostEqual(c["price"], 4.76, places=2)
        self.assertAlmostEqual(p["price"], 0.81, places=2)
        self.assertAlmostEqual(c["delta"] - p["delta"], 1.0, places=6)

    def test_implied_vol_roundtrip(self):
        price = quant.bs("call", 100, 105, 0.25, 0.35)["price"]
        self.assertAlmostEqual(quant.implied_vol("call", price, 100, 105, 0.25), 0.35, places=4)

    def test_bull_call_spread(self):
        legs = [{"kind": "call", "strike": 190, "expiration": "2030-01-18", "qty": 1, "price": 11.35, "iv": 0.5},
                {"kind": "call", "strike": 205, "expiration": "2030-01-18", "qty": -1, "price": 5.60, "iv": 0.5}]
        r = quant.payoff(legs, 185, today=__import__("datetime").date(2030, 1, 18))
        self.assertEqual(r["net_cost"], 575.0)
        self.assertAlmostEqual(r["max_loss"], -575.0, places=0)
        self.assertAlmostEqual(r["max_profit"], 925.0, places=0)
        self.assertAlmostEqual(r["break_evens"][0], 195.75, delta=0.2)

    def test_naked_short_call_unbounded(self):
        r = quant.payoff([{"kind": "call", "strike": 100, "expiration": "2030-01-18", "qty": -1, "price": 3}], 100,
                         today=__import__("datetime").date(2030, 1, 18))
        self.assertIsNone(r["max_loss"])

    def test_position_size(self):
        r = quant.position_size(100000, 50, 48, risk_pct=1)
        self.assertEqual((r["qty"], r["risk_usd"], r["side"]), (500, 1000.0, "buy (long)"))
        self.assertEqual(quant.position_size(100000, 50, 52, risk_usd=500)["side"], "sell (short)")

    def test_backtest(self):
        bars = [{"c": 100 + i} for i in range(120)]
        r = quant.backtest(bars, "sma_cross")
        self.assertGreater(r["total_return_pct"], 0)
        self.assertEqual(quant.backtest(bars)["max_drawdown_pct"], 0.0)
