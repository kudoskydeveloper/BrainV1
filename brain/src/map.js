// Brain map: everything Brain works with, as nodes the Brain app draws (Brain window → Mapa), and the switch to turn a part
// off. Off parts are in brain.config.json "off" (node ids); Brain refuses their tools, their `call`s and their proposals,
// and leaves them out of search_everywhere and where_is. `node src/map.js` prints the map, `node src/map.js set <id> on|off`
// changes one switch (the Brain app runs these).
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { CONFIG, HOME, ICLOUD } from "./paths.js";
import { readJSON } from "./store.js";
import { loadServers } from "./registry.js";

// Brain's own parts: which of its tools belong to each. Hangar apps carry their bundle id (the app draws their icon).
const BUILTIN = [
  { id: "whatsapp", name: "WhatsApp", group: "komunikacia", symbol: "phone.bubble.fill", tools: /^whatsapp_/ },
  { id: "messenger", name: "Messenger a Beeper", group: "komunikacia", symbol: "bubble.left.and.bubble.right.fill", tools: /^messenger_/ },
  { id: "calendar", name: "Kalendár", group: "komunikacia", symbol: "calendar", tools: /^calendar_|^celebrations$/ },
  { id: "reminders", name: "Pripomienky", group: "komunikacia", symbol: "checklist", tools: /^reminders_/ },
  { id: "apple_notes", name: "Apple Notes", group: "komunikacia", symbol: "note.text", tools: /^apple_notes_/ },
  { id: "photos", name: "Fotky", group: "apple", app: "com.apple.Photos", symbol: "photo.on.rectangle", tools: /^photos_/ },
  { id: "maps", name: "Mapy a cesty", group: "apple", app: "com.apple.Maps", symbol: "map.fill", tools: /^travel_/ },
  { id: "weather", name: "Počasie", group: "apple", app: "com.apple.weather", symbol: "cloud.sun.fill", tools: /^weather$/ },
  { id: "shortcuts", name: "Skratky", group: "apple", app: "com.apple.shortcuts", symbol: "square.2.layers.3d.fill", tools: /^shortcuts_list$|^shortcut_run$/ },
  { id: "voice_memos", name: "Hlasové poznámky", group: "apple", app: "com.apple.VoiceMemos", symbol: "waveform", tools: /^voice_memos$|^voice_memo$/ },
  { id: "safari", name: "Safari", group: "apple", app: "com.apple.Safari", symbol: "safari.fill", tools: /^safari_/ },
  { id: "meetings", name: "Meetings", group: "hangar", app: "com.lockedin.meetings", symbol: "person.wave.2.fill", tools: /^meetings$|^meeting_prep$|^fathom_import$|^client$/ },
  { id: "people", name: "Ľudia", group: "hangar", app: "com.lockedin.ludia", symbol: "person.2.fill", tools: /^people_|^person|^who$/ },
  { id: "home", name: "Home", group: "hangar", app: "com.lockedin.home", symbol: "house.fill", tools: /^shopping_|^home_/ },
  { id: "fitness", name: "Fitness", group: "hangar", app: "com.lockedin.fitness", symbol: "figure.run", tools: /^fitness_overview$/ },
  { id: "trading", name: "MarketBar a trading", group: "hangar", app: "com.lockedin.marketbar", symbol: "chart.line.uptrend.xyaxis", tools: /^market_|^marketbar$|^trading_plan/ },
  { id: "finance_overview", name: "Prehľad financií", group: "peniaze", symbol: "eurosign.circle.fill", tools: /^finance_overview$/ },
  { id: "hevy", name: "Hevy", group: "zdravie", symbol: "dumbbell.fill", tools: /^hevy_/ },
  { id: "strava", name: "Strava", group: "zdravie", symbol: "bicycle", tools: /^strava_/ },
  { id: "health", name: "Zdravie (Apple Health)", group: "zdravie", symbol: "heart.fill", tools: /^health$/ },
  { id: "idoklad", name: "iDoklad", group: "peniaze", symbol: "doc.text.fill", tools: /^idoklad_/ },
  { id: "files", name: "Súbory a priečinky", group: "subory", symbol: "folder.fill", tools: /^where_is$|^folder_overview$|^read_file$|^write_file$|^file_action$|^cleanup_plan$|^save_|^semantic_/ },
  { id: "memory", name: "Pamäť", group: "brain", symbol: "brain", tools: /^remember$|^recall$|^forget$|^writing_style$/ },
  { id: "timers", name: "Timery", group: "brain", symbol: "alarm.fill", tools: /^schedule$|^timers$|^timer_cancel$/ },
];

// MCP servers Brain routes to with `call`: nicer names and where they belong. Unknown ones go to "ine".
const SERVERS = {
  courier: { name: "Courier", group: "hangar", app: "com.lockedin.courier", symbol: "envelope.fill" },
  faktury: { name: "Faktúry", group: "hangar", app: "com.lockedin.faktury", symbol: "doc.richtext.fill" },
  financie: { name: "Financie", group: "hangar", app: "com.lockedin.financie", symbol: "banknote.fill" },
  recepty: { name: "Recepty", group: "hangar", app: "com.lockedin.recepty", symbol: "fork.knife.circle.fill" },
  "market-alerts": { name: "Alpaca (market-alerts)", group: "peniaze", symbol: "chart.bar.fill" },
  myfitnesspal: { name: "MyFitnessPal", group: "zdravie", symbol: "fork.knife" },
  todoist: { name: "Todoist (Kudosky)", group: "praca", symbol: "checkmark.circle.fill" },
  "todoist-10t": { name: "Todoist (10T)", group: "praca", symbol: "checkmark.circle.fill" },
  linkedin: { name: "Herald (LinkedIn)", group: "hangar", app: "com.lockedin.herald", symbol: "flag.fill" },
  kuboard: { name: "Kuboard (Kudosky CRM)", group: "praca", symbol: "rectangle.split.3x1.fill" },
  scout: { name: "Scout (e-maily firiem)", group: "hangar", app: "com.lockedin.scout", symbol: "binoculars.fill" },
  selleriz: { name: "Selleriz", group: "praca", symbol: "person.crop.rectangle.stack.fill" },
  "daktela-write": { name: "Daktela", group: "praca", symbol: "headphones" },
  "daktela-main-write": { name: "Daktela (main)", group: "praca", symbol: "headphones" },
  "thunderbird-mail": { name: "Thunderbird", group: "komunikacia", symbol: "envelope.badge.fill" },
  Figma: { name: "Figma", group: "ine", symbol: "paintpalette.fill" },
  Blender: { name: "Blender", group: "ine", symbol: "cube.fill" },
  Spline: { name: "Spline", group: "ine", symbol: "cube.transparent.fill" },
  "daktela-test": { name: "Daktela (test)", group: "praca", symbol: "headphones" },
  "weare10t-chat": { name: "10T Base (CRM a chatboty)", group: "praca", symbol: "bubble.left.fill" },
  "dev-mode-mcp-server-dxt": { name: "Dev mode MCP", group: "ine", symbol: "hammer.fill" },
};

/** Folders where_is and the file tools look in. */
export const FOLDERS = [
  ["iCloud Drive", ICLOUD], ["Dokumenty", path.join(HOME, "Documents")], ["Plocha", path.join(HOME, "Desktop")],
  ["Stiahnuté", path.join(HOME, "Downloads")], ["Developer", path.join(HOME, "Developer")], ["Archive", path.join(HOME, "Archive")],
  ["Obrázky", path.join(HOME, "Pictures")], ["Market briefs", path.join(HOME, "Market briefs")], ["Google Drive", path.join(HOME, "Library/CloudStorage")],
];

/** Brain tools that are Brain itself (asking, routing, confirming): always on, not a part of the map. */
export const CORE = new Set(["overview", "search_everywhere", "capabilities", "call", "confirm", "claude_account", "morning_brief", "scan_now"]);

/** Every tool the Brain MCP registers, read from server.js (each one is `tool("name", …)` at the start of a line). */
export function toolNames() {
  try {
    const src = fs.readFileSync(path.join(path.dirname(fileURLToPath(import.meta.url)), "server.js"), "utf8");
    return [...src.matchAll(/^tool\("([a-z0-9_]+)"/gm)].map((m) => m[1]);
  } catch { return []; }
}

/** Tools no part claims yet: grouped by their prefix ("notion_search" → "notion") into parts of the "nove" group, so a new
 *  feature shows on the map (and can be switched off) the moment it exists. Give it a real part in BUILTIN afterwards. */
export function newParts() {
  const parts = {};
  for (const t of toolNames()) {
    if (CORE.has(t) || BUILTIN.some((b) => b.tools.test(t))) continue;
    const k = t.split("_")[0];
    (parts[k] ||= []).push(t);
  }
  return Object.entries(parts).map(([k, tools]) => ({ id: "new:" + k, name: k.charAt(0).toUpperCase() + k.slice(1), tools }));
}

/** Apps of the Hangar series (com.lockedin.*) installed on this Mac, so a new one shows even before Brain uses it. */
export function hangarApps() {
  const out = [];
  for (const dir of [path.join(HOME, "Applications"), "/Applications"]) {
    let names = []; try { names = fs.readdirSync(dir).filter((n) => n.endsWith(".app")); } catch { continue; }
    for (const n of names) {
      let plist = ""; try { plist = fs.readFileSync(path.join(dir, n, "Contents/Info.plist"), "utf8"); } catch { continue; }
      const id = plist.match(/<key>CFBundleIdentifier<\/key>\s*<string>(com\.lockedin\.[^<]+)<\/string>/)?.[1];
      if (id && !out.some((a) => a.id === id)) out.push({ id, name: n.replace(/\.app$/, "") });
    }
  }
  return out;
}

export const GROUPS = {
  hangar: "Hangar appky", komunikacia: "Komunikácia", praca: "Práca", peniaze: "Peniaze",
  zdravie: "Zdravie", apple: "Apple appky", subory: "Súbory", brain: "Brain", ine: "Iné appky", nove: "Nové (zatiaľ nezaradené)",
};

export const off = () => new Set(readJSON(CONFIG, {}).off || []);
export const isOff = (id) => off().has(id);
export const folderId = (name) => `folder:${name}`;
export const serverId = (name) => `mcp:${name}`;

/** Which part a Brain tool belongs to (null: always on, like overview or confirm). */
export function partOf(tool) {
  if (CORE.has(tool)) return null;
  return BUILTIN.find((b) => b.tools.test(tool))?.id || "new:" + tool.split("_")[0];
}

export const label = (id) => BUILTIN.find((b) => b.id === id)?.name || SERVERS[id.replace(/^mcp:/, "")]?.name || id.replace(/^(mcp|folder):/, "");
const refuse = (id) => { throw new Error(`${label(id)} je v Brain mape vypnuté. Povedz to používateľovi; zapne ho v okne Brain → Mapa.`); };

/** Throws when the tool (or the server a `call` goes to) is switched off. */
export function guard(tool, args = {}) {
  const o = off();
  if (!o.size) return;
  const part = partOf(tool);
  if (part && o.has(part)) refuse(part);
  if (tool === "call" && args.server && o.has(serverId(args.server))) refuse(serverId(args.server));
}

/** Throws when a proposal would act on a part that is off now (it may have been switched off after it was proposed). */
export function guardAction(a) {
  const o = off();
  if (!o.size) return;
  if (a.type === "whatsapp" && o.has("whatsapp")) refuse("whatsapp");
  if (String(a.type).startsWith("beeper") && o.has("messenger")) refuse("messenger");
  if (a.type === "call" && o.has(serverId(a.server))) refuse(serverId(a.server));
  if (String(a.type).startsWith("file") && o.has("files")) refuse("files");
  if (a.type === "shortcut" && o.has("shortcuts")) refuse("shortcuts");
  if (a.type === "photos_album" && o.has("photos")) refuse("photos");
}

/** The map: Brain in the middle, groups, and every part with its switch. */
export function map() {
  const o = off();
  const nodes = BUILTIN.map((b) => ({ id: b.id, name: b.name, group: b.group, kind: "brain", symbol: b.symbol, app: b.app,
    on: !o.has(b.id), detail: `Nástroje Brainu (${b.tools.source.replace(/[\^$\\]/g, "").replaceAll("|", ", ")})` }));
  let servers = {};
  try { servers = loadServers(); } catch {}
  for (const [n, s] of Object.entries(servers)) {
    const k = SERVERS[n] || { name: n, group: "ine", symbol: "puzzlepiece.extension.fill" };
    nodes.push({ id: serverId(n), name: k.name, group: k.group, kind: "mcp", symbol: k.symbol, app: k.app, on: !o.has(serverId(n)),
      detail: s.routable ? `MCP server (${s.from.join(", ")})` : `MCP server, Brain ho nevolá: ${s.note || "nemá príkaz"}`, usable: s.routable });
  }
  for (const p of newParts()) {
    nodes.push({ id: p.id, name: p.name, group: "nove", kind: "brain", symbol: "sparkles", on: !o.has(p.id),
      detail: `Nová funkcia Brainu, zatiaľ bez miesta v mape (${p.tools.join(", ")}). Zaraď ju v brain/src/map.js (BUILTIN).` });
  }
  // Hangar apps on this Mac that no part stands for yet (e.g. a brand-new app in the series)
  const known = new Set(nodes.map((n) => n.app).filter(Boolean).concat("com.lockedin.brain", "com.lockedin.hangar"));
  for (const a of hangarApps()) {
    if (known.has(a.id)) continue;
    nodes.push({ id: "app:" + a.id, name: a.name, group: "hangar", kind: "app", symbol: "app.fill", app: a.id, on: !o.has("app:" + a.id),
      detail: `Hangar appka (${a.id}). Brain s ňou zatiaľ nepracuje: keď dostane nástroje alebo MCP server, pribudnú tu.` });
  }
  for (const [n, f] of FOLDERS) {
    if (!fs.existsSync(f)) continue;
    nodes.push({ id: folderId(n), name: n, group: "subory", kind: "folder", symbol: n === "Google Drive" ? "externaldrive.fill.badge.icloud" : n === "iCloud Drive" ? "icloud.fill" : "folder.fill",
      on: !o.has(folderId(n)), detail: f.replace(HOME, "~"), path: f });
  }
  return { groups: GROUPS, nodes, off: [...o] };
}

/** Turns one part on or off (brain.config.json "off"). */
export function set(id, on) {
  const cfg = readJSON(CONFIG, {});
  const o = new Set(cfg.off || []);
  if (on) o.delete(id); else o.add(id);
  cfg.off = [...o].sort();
  if (!cfg.off.length) delete cfg.off;
  const tmp = CONFIG + ".tmp";   // same 2-space format the file is kept in
  fs.writeFileSync(tmp, JSON.stringify(cfg, null, 2) + "\n");
  fs.renameSync(tmp, CONFIG);
  return { id, on: !!on, off: cfg.off || [] };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [cmd, id, state] = process.argv.slice(2);
  const out = cmd === "set" ? set(id, state !== "off") : map();
  process.stdout.write(JSON.stringify(out) + "\n");
}
