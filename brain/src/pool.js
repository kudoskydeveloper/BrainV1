import path from "node:path";
// Lazily started MCP clients, one per server, closed again after a few idle minutes.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { loadServers } from "./registry.js";
import * as oauth from "./oauth.js";
import { config } from "./store.js";

const clients = new Map();   // name -> { client, timer }

function withTimeout(promise, ms, what) {
  let t;
  return Promise.race([promise, new Promise((_, rej) => { t = setTimeout(() => rej(new Error(`${what} timed out after ${ms / 1000}s`)), ms); })])
    .finally(() => clearTimeout(t));
}

// Apps started from the Dock (Brain, CRM, …) get macOS's minimal PATH, without /usr/local/bin or Homebrew, so a server
// launched through npx or a #!/usr/bin/env node script (e.g. the 10T bridge, `npx mcp-remote`) dies at once with
// "Connection closed". Servers get the usual places added after whatever PATH there is.
function fullPath() {
  const have = (process.env.PATH ?? "").split(":").filter(Boolean);
  const add = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", path.dirname(process.execPath), "/usr/bin", "/bin", "/usr/sbin", "/sbin"];
  return [...new Set([...have, ...add])].join(":");
}

export async function client(name) {
  const hit = clients.get(name);
  if (hit) { touch(name, hit); return hit.client; }
  const s = loadServers()[name];
  if (!s) throw new Error(`unknown server "${name}"`);
  if (!s.routable) throw new Error(`${name} is not routable: ${s.note}`);
  const transport = s.url ? oauth.transport(name, s.url) : new StdioClientTransport({
    command: s.command, args: s.args, env: { ...process.env, PATH: fullPath(), ...s.env }, stderr: "ignore",
  });
  const c = new Client({ name: "brain", version: "0.1.0" });
  await withTimeout(c.connect(transport), 30000, `starting ${name}`);
  const entry = { client: c, timer: null };
  clients.set(name, entry);
  touch(name, entry);
  return c;
}

function touch(name, entry) {
  clearTimeout(entry.timer);
  entry.timer = setTimeout(() => close(name), config().idle_close_minutes * 60000);
  entry.timer.unref?.();
}

export async function close(name) {
  const e = clients.get(name);
  if (!e) return;
  clients.delete(name);
  clearTimeout(e.timer);
  await e.client.close().catch(() => {});
}

export async function closeAll() { await Promise.all([...clients.keys()].map(close)); }

export async function listTools(name) {
  const c = await client(name);
  const r = await withTimeout(c.listTools(), 30000, `listing ${name} tools`);
  return r.tools;
}

export async function callTool(name, tool, args, ms = 60000) {
  const c = await client(name);
  return withTimeout(c.callTool({ name: tool, arguments: args || {} }), ms, `${name}.${tool}`);
}

/** Text of a tool result, joined. */
export function resultText(r) {
  return (r?.content || []).filter((c) => c.type === "text").map((c) => c.text).join("\n");
}
