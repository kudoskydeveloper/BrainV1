# Hangar

A small Dock app with all my own apps (bundle id `com.lockedin.*` in `~/Applications` or `/Applications`): click opens the app
(menu bar apps through their URL, e.g. Brain's panel, MarketBar's brief), right-click has their other actions, restart, quit
and Show in Finder. A green dot means it's running. New apps in the series appear by themselves.

- Build and install: `./build-app.sh`, then keep it in the Dock.
- Icon: `Icon/make-icns.sh` (same family as Brain and MarketBar: gradient rounded square, glow, white SF Symbol).
- Per-app actions and subtitles: `MyApp.known` / `MyApp.subtitle` in `Sources/Hangar/HangarApp.swift`.
