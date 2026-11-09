# Brain (MCP server)

## Brain map: keep it complete

The Brain app draws everything Brain works with as a map (Brain window → Mapa) and lets the user switch parts off. The map
comes from `src/map.js`. Whenever a feature is added, it must get its place there in the same change:

- **New tool in `src/server.js`**: add it to a part in `BUILTIN` in `src/map.js` (a matching `tools` regex in an existing part,
  or a new part with id, name, group, SF Symbol, and `app` bundle id if it belongs to a Hangar app). Brain-core tools that
  must never be switched off go to `CORE`. Until then it shows under "Nové (zatiaľ nezaradené)" and `npm test` fails
  (`test/map.test.js`).
- **New MCP server Brain calls**: it appears by itself (from `registry.js`); give it a name, group and symbol in `SERVERS`.
- **New Hangar app (`com.lockedin.*`)**: it appears by itself once installed; when Brain gets tools for it, point their part's
  `app` at its bundle id.
- **New folder Brain searches**: add it to `FOLDERS` (and to `SCOPES` in `src/find.js`).

Switched-off parts live in `brain.config.json` → `"off"`; `map.guard` (tool wrapper), `map.guardAction` (confirm),
`search.js` and `find.js` enforce them, so a new source that bypasses these needs its own `isOff` check.

Run `npm test` before committing.
