import fs from "node:fs";
import path from "node:path";
import { CONFIG, DATA } from "./paths.js";

export function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return fallback; }
}

export function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(value, null, 1));
  fs.renameSync(tmp, file);
}

export function appendLine(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.appendFileSync(file, JSON.stringify({ at: new Date().toISOString(), ...obj }) + "\n");
}

const DEFAULTS = {
  // tools that run without a confirm step even though they write ("server:tool" or "server:*")
  auto_confirm: ["brain:remember", "brain:forget", "market-alerts:update_watchlist"],
  // MCP sources search_everywhere asks, with the tool and how the query is passed
  sources: {},
  // email digest during the nightly scan
  digest: { email: true },
  idle_close_minutes: 5,
};

export function config() {
  return { ...DEFAULTS, ...readJSON(CONFIG, {}) };
}

export function ensureDirs() { fs.mkdirSync(DATA, { recursive: true }); }
