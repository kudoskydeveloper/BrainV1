# market-alerts

Daily market brief, price alerts and a paper-trade log from an **Alpaca paper account**. Python 3.9 standard library only.

## Setup
1. Alpaca → Paper account → API keys → generate.
2. `cp ~/.config/market-alerts/keys.env.example ~/.config/market-alerts/keys.env`, fill in both values.
3. Try it: `python3 -m market_alerts brief --dry-run`
4. Schedule it: `./install.sh`

## What runs (Mac local time)

The brief and alerts now run in the MarketBar app (~/Developer/MarketBar); their launchd jobs were retired (plists kept as `launchd-disabled-*.plist`). Only `trades` still runs from launchd.

| Job | When | Does |
|---|---|---|
| brief | weekdays 08:30, 15:15 | writes `~/Market briefs/YYYY-MM-DD.md` (not iCloud: background jobs may not write there), notification with top movers |
| alerts | every 15 min, market hours only | notification when a symbol moves ≥ `move_alert_pct` or crosses a level; once per rule per day |
| trades | weekdays 22:30 | exports filled paper orders to `paper-trades.csv` in the same folder |

Edit `watchlist.json` for symbols, the move threshold and price levels. Log: `~/Library/Logs/market-alerts.log`.

Only the paper endpoint is used (`paper-api.alpaca.markets`); nothing here places orders.

Tests: `python3 -m unittest discover -s tests -t .`

## Talking to it from Claude (MCP)
`market_alerts/mcp_server.py` is a stdio MCP server, registered in Claude Code (user scope) and the Claude Desktop profiles as `market-alerts`.
Tools: account, positions, quote, brief, watchlist, update_watchlist, orders, propose_order, propose_exit, propose_replace, commit_order, cancel_order.
Orders are two-step: `propose_order` checks limits (`trading` in watchlist.json: max_order_usd, allowed_symbols, proposal_minutes) and returns a single-use proposal id; `commit_order` places it.
- `propose_order`: market, limit, stop, stop_limit, trailing_stop; `take_profit_price` / `stop_loss_price` (+ `stop_loss_limit_price`) on a market or limit entry make a bracket (both) or OTO (one); with legs `time_in_force` defaults to GTC (a DAY bracket's legs lapse at the close and the summary warns about it).
- `propose_exit`: protect an open position: take profit + stop loss as OCO, just one of them, or a trailing stop; at most the position's size, GTC by default.
- `propose_replace`: move an open order's stop/limit price, qty, trail or time in force (bracket legs are listed inside their parent in `orders`).
Prices are checked against the side (a long's take profit above, stop below the price). Paper endpoint only. Placed/cancelled orders are logged to `~/.local/state/market-alerts/orders.jsonl`.
