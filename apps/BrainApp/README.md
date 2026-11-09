# Brain (app)

Menu bar app with a global **⌥Space** panel. Questions go to Claude Code in headless mode (`claude -p`) with only the Brain MCP
(`~/Developer/brain/brain-only.mcp.json`), so answers come from your files, projects, notes and connected sources.
Follow-ups resume the same session, so "yes" confirms a Brain proposal. **Continue in Claude** copies the conversation and opens Claude Desktop.

- Photos: the picture button (or dragging a picture in, from Finder or Photos) attaches photos to the question; they go to the
  model as images (it sees what's on them, e.g. a meal for calories), stored as JPEGs in `~/Library/Application Support/Brain/attachments`
  with their paths in the question, so Brain's tools (read_file OCR) can use them too. `brain://ask?q=…&image=<path>` does the same from scripts.
- Build + install: `./build-app.sh` → `~/Applications/Brain.app` (opens at login)
- Tests: `swift test` (stream parser)
- Log: `~/Library/Logs/Brain.log`
- Needs the `claude` CLI logged in: type `/login` in the panel (runs `claude auth login`, sign-in in the browser; falls back to Terminal). Runs drop the `CLAUDE*` variables of a Claude Code session that launched the app, so they use your own login. Model: sonnet (Runner.model).
- Claude account and commands: the ⓘ icon in the panel shows the account, a switch button and every command; `/ucet` shows the account; `/relogin [e-mail]` (or the menu item, or the button when the usage limit is used up) logs out and signs in with another one in the browser.
- Icon: `Icon/make-icon.swift`
