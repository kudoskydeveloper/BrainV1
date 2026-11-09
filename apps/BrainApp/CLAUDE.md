# Brain app

- When a feature is added to Brain (a new tool, part, Hangar app or folder), it must also show on the Brain map: the map's
  data comes from the Brain MCP repo, `~/Developer/brain/src/map.js` (see its `CLAUDE.md`); this app only draws it
  (`Sources/Brain/MapView.swift`). A new group there needs a color in `MapStore.color` and a place in `MapStore.order`.
- Design: flat and minimal (near-white panel surface, solid `Color.brainAccent`, slim chips), no gradients except the brain
  icon's purple → indigo. Check UI with `Brain --window-snapshot <dir>` (renders every window section and the panel to PNG).
- `./build-app.sh` builds and installs to ~/Applications (restarts Brain).
