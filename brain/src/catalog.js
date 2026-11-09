// Cached tool lists of every server, read-only/write classification, and keyword search over them.
import { listTools } from "./pool.js";
import { loadServers, NEVER, NOT_ROUTED } from "./registry.js";
import { p } from "./paths.js";
import { readJSON, writeJSON } from "./store.js";

const CACHE = p("tools.json");
const READ_NAME = /^(get|list|search|read|count|find|fetch|query|describe|check|status|show|view|lookup|playbook|recall|where|quote|account|positions|watchlist|orders|brief|capabilities)/i;
const PROPOSE = /^(propose|dry_?run|prepare|preview)/i;

const COMMIT = /^commit/i;

/** "read" runs straight away; "write" needs Brain's confirm unless auto-confirmed.
 *  propose_* only drafts (read); commit_* is step 2 of the server's own confirm flow, so Brain doesn't ask twice. */
export function kind(tool) {
  const a = tool.annotations || {};
  if (a.readOnlyHint === true) return "read";
  const base = tool.name.replace(/^[a-z0-9]+_(?=(get|list|search|read|propose|commit|send|create|update|delete))/i, "");
  if (COMMIT.test(base)) return "commit";
  if (a.destructiveHint === true) return "write";
  if (PROPOSE.test(base) || READ_NAME.test(base)) return "read";
  return "write";
}

export async function refresh(only) {
  const cache = readJSON(CACHE, {});
  const servers = loadServers();
  await Promise.all(Object.values(servers).map(async (s) => {
    if (only && s.name !== only) return;
    if (!s.routable) { cache[s.name] = { note: s.note, tools: [] }; return; }
    try {
      const tools = await listTools(s.name);
      cache[s.name] = {
        at: new Date().toISOString(),
        tools: tools.map((t) => ({ name: t.name, description: (t.description || "").slice(0, 400), kind: kind(t), inputSchema: t.inputSchema })),
      };
    } catch (e) {
      cache[s.name] = { ...(cache[s.name] || {}), error: String(e.message || e) };
    }
  }));
  for (const n of Object.keys(cache)) if (!servers[n]) delete cache[n];
  writeJSON(CACHE, cache);
  return cache;
}

/** The cache without servers Brain never uses (a cache written before they were dropped may still hold them). */
export function cached() { return Object.fromEntries(Object.entries(readJSON(CACHE, {})).filter(([n]) => !NEVER.test(n))); }

export function findTool(server, tool) {
  return cached()[server]?.tools?.find((t) => t.name === tool);
}

/** Keyword search over server/tool names and descriptions. */
export function search(query, limit = 25) {
  const words = String(query || "").toLowerCase().split(/\s+/).filter(Boolean);
  const hits = [];
  for (const [server, v] of Object.entries(cached())) {
    if (NOT_ROUTED[server]) continue;   // Brain reads it itself, but nobody calls it (NEVER ones are already out of cached())
    for (const t of v.tools || []) {
      const hay = `${server} ${t.name} ${t.description}`.toLowerCase();
      const score = words.length ? words.filter((w) => hay.includes(w)).length : 1;
      if (score) hits.push({ score: score + (t.name.toLowerCase().includes(words[0] || "\0") ? 1 : 0), server, ...t });
    }
  }
  return hits.sort((a, b) => b.score - a.score).slice(0, limit);
}
