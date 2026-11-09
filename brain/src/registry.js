// Every MCP server configured for Claude Code (user scope) and the Claude Desktop profiles, plus the Claude Desktop
// extensions (.mcpb) that are enabled and need no settings of their own.
import fs from "node:fs";
import path from "node:path";
import { HOME } from "./paths.js";
import { config, readJSON } from "./store.js";

/** Servers Brain never loads, lists or calls: Spark. The user's only mail client is Courier and the calendar is Apple Calendar
 *  through calendar_* (it was once wrongly suggested as a way to create calendar events, so never offer it). */
export const NEVER = /^spark\b/i;

/** Servers Brain may read old history from itself (search), but never offers through capabilities / call: mail goes
 *  through Courier only. */
export const NOT_ROUTED = { "thunderbird-mail": "Thunderbird is only old mail history; read and write e-mail through Courier (call courier.*: list_messages, search, thread, draft, propose_send)." };

export function loadServers() {
  const out = {};
  const add = (name, def, from) => {
    if (name === "brain" || NEVER.test(name)) return;
    if (out[name]) { out[name].from.push(from); return; }
    const remote = def.type === "http" || def.type === "sse" || def.url;
    out[name] = {
      name, from: [from],
      routable: !remote && !!def.command,
      command: def.command, args: def.args || [], env: def.env || {},
      note: remote ? "remote (HTTP) server with its own login; use it from Claude directly" : undefined,
    };
  };
  // remote servers Brain signs in to itself (oauth.js): brain.config.json "remote": { name: url }
  for (const [n, url] of Object.entries(config().remote || {})) {
    out[n] = { name: n, from: ["Brain (remote, OAuth)"], routable: true, url, args: [], env: {} };
  }
  const code = readJSON(path.join(HOME, ".claude.json"), {});
  for (const [n, d] of Object.entries(code.mcpServers || {})) add(n, d, "Claude Code");
  // the other Claude Code profiles (~/.claude-10T, ~/.claude-<account>): a server added in one of them counts too
  for (const dir of fs.readdirSync(HOME).filter((d) => /^\.claude-/.test(d))) {
    const other = readJSON(path.join(HOME, dir, ".claude.json"), null);
    for (const [n, d] of Object.entries(other?.mcpServers || {})) add(n, d, `Claude Code (${dir.slice(1)})`);
  }
  const support = path.join(HOME, "Library/Application Support");
  for (const dir of fs.readdirSync(support).filter((d) => d.startsWith("Claude"))) {
    const cfg = readJSON(path.join(support, dir, "claude_desktop_config.json"), null);
    for (const [n, d] of Object.entries(cfg?.mcpServers || {})) add(n, d, `Claude Desktop (${dir})`);
    for (const [n, d] of extensions(path.join(support, dir))) add(n, d, `Claude Desktop extension (${dir})`);
  }
  return out;
}

/** [name, { command, args, env }] of each enabled extension in one Claude Desktop profile. */
function extensions(profile) {
  const root = path.join(profile, "Claude Extensions");
  let ids; try { ids = fs.readdirSync(root); } catch { return []; }
  const out = [];
  for (const id of ids) {
    if (readJSON(path.join(profile, "Claude Extensions Settings", `${id}.json`), {}).isEnabled === false) continue;
    const dir = path.join(root, id), m = readJSON(path.join(dir, "manifest.json"), null);
    const c = m?.server?.mcp_config;
    if (!c?.command) continue;
    const def = JSON.parse(JSON.stringify(c).replaceAll("${__dirname}", dir.replace(/[\\"]/g, "\\$&")));
    if (JSON.stringify(def).includes("${")) continue;   // needs user settings Brain can't see
    if (def.command === "node") def.command = process.execPath;   // Claude Desktop ships its own node; ours is the one running Brain
    out.push([m.name || id, def]);
  }
  return out;
}
