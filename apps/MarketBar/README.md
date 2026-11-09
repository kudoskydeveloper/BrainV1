# MarketBar

Menu bar app for an Alpaca **paper** account: live watchlist (IEX stream), sparklines, native alerts, a brief window at 08:30 and 15:15 on weekdays, settings, opens at login.

Shares `~/Developer/market-alerts/watchlist.json` and `~/.config/market-alerts/keys.env` with the Python tools there, so changes made by Claude through the `market-alerts` MCP server show up here within 30 s.

- Market hours (Alpaca clock, holidays and early closes included): chime notification at the open and the close (`Sounds/market-open.wav` / `market-close.wav`, drawn by `Sounds/make-sounds.py`), a warning 15 min before the close, countdown in the menu bar (timer = to the close, moon = to the open when under a day) and in the menu with a session progress bar. Toggles in Settings → Market hours.
- Protection check (market hours, every 5 min): one notification a day per position with no stop loss, a partial one, or only a DAY stop that lapses at the close.
- Build + install: `./build-app.sh` → `~/Applications/MarketBar.app`
- Tests: `swift test`
- Links: `marketbar://brief`, `marketbar://brief-now`, `marketbar://settings`
- Briefs: iCloud `Personal/Finance/Market briefs/`, falling back to `~/Market briefs/`
- Icon: `Icon/make-icon.swift` draws `Icon/icon-1024.png`; `AppIcon.icns` is built from it with `iconutil`
