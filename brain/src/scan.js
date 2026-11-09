// Nightly scan: projects in ~/Developer, Chrome bookmarks, every server's tools, and (opt-in) the email digest.
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import * as catalog from "./catalog.js";
import * as fathom from "./fathom.js";
import { importRecapEmails } from "./fathom-mail.js";
import { addMeetingTasks } from "./autotasks.js";
import { buildIndex } from "./semantic.js";
import { buildPeople } from "./people.js";
import * as wa from "./whatsapp.js";
import * as beeper from "./beeper.js";
import { HOME, p } from "./paths.js";
import { callTool, closeAll, resultText } from "./pool.js";
import { appendLine, config, readJSON, writeJSON } from "./store.js";
import { status } from "./ui.js";

const run = promisify(execFile);

async function tags(dir) {
  try { const { stdout } = await run("mdls", ["-raw", "-name", "kMDItemUserTags", dir]); return [...stdout.matchAll(/"?([^"\n(),]+)"?/g)].map((m) => m[1].trim()).filter((t) => t && t !== "null"); }
  catch { return []; }
}

async function remote(dir) {
  try { const { stdout } = await run("git", ["-C", dir, "remote", "get-url", "origin"], { timeout: 5000 }); return stdout.trim().replace(/^.*github\.com[:/]/, "github:").replace(/\.git$/, ""); }
  catch { return undefined; }
}

function summary(dir) {
  for (const f of ["README.md", "readme.md", "CLAUDE.md", "package.json"]) {
    const file = path.join(dir, f);
    if (!fs.existsSync(file)) continue;
    const t = fs.readFileSync(file, "utf8").slice(0, 4000);
    if (f === "package.json") { try { return JSON.parse(t).description || JSON.parse(t).name; } catch { continue; } }
    const line = t.split("\n").map((l) => l.replace(/^#+\s*/, "").trim()).find((l) => l && !l.startsWith("!["));
    const next = t.split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#") && !l.startsWith("!["))[0];
    return [line, next].filter(Boolean).join(" — ").slice(0, 240);
  }
}

export async function scanProjects() {
  const root = path.join(HOME, "Developer");
  const dirs = fs.readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory() && !d.name.startsWith("."));
  const nested = ["10Tstudios"];   // folders that hold several projects
  const list = [];
  for (const d of dirs) {
    const full = path.join(root, d.name);
    list.push(full);
    if (nested.includes(d.name)) for (const s of fs.readdirSync(full, { withFileTypes: true })) if (s.isDirectory() && !s.name.startsWith(".") && !s.name.startsWith("wt-")) list.push(path.join(full, s.name));
  }
  const projects = await Promise.all(list.map(async (dir) => {
    const t = await tags(dir);
    return { name: path.basename(dir), path: dir, business: t.join(", ") || undefined, remote: await remote(dir), summary: summary(dir),
             modified: fs.statSync(dir).mtime.toISOString().slice(0, 10) };
  }));
  writeJSON(p("projects.json"), projects);
  return projects.length;
}

export function scanBookmarks() {
  const file = path.join(HOME, "Library/Application Support/Google/Chrome/Default/Bookmarks");
  const roots = readJSON(file, {}).roots || {};
  const out = [];
  const walk = (n, folder) => (n.children || []).forEach((x) => x.type === "folder" ? walk(x, folder ? `${folder}/${x.name}` : x.name) : out.push({ title: x.name, url: x.url, folder }));
  ["bookmark_bar", "other"].forEach((k) => roots[k] && walk(roots[k], ""));
  writeJSON(p("bookmarks.json"), out);
  return out.length;
}

/** Senders of the last day's mail into people.json: name, email, how often, last subject and date. Needs Thunderbird running. */
export async function digestEmail() {
  const t = catalog.findTool("thunderbird-mail", "getRecentMessages");
  if (!t) return "skipped: thunderbird-mail tools unknown (Thunderbird not running at scan time?)";
  const props = Object.keys(t.inputSchema?.properties || {});
  const args = {};
  for (const k of props) {
    if (/day/i.test(k)) args[k] = 2;
    else if (/hour/i.test(k)) args[k] = 48;
    else if (/limit|max|count/i.test(k)) args[k] = 200;
  }
  const r = await callTool("thunderbird-mail", "getRecentMessages", args, 90000);
  let msgs; try { msgs = JSON.parse(resultText(r)); } catch { return "skipped: unexpected email format"; }
  msgs = Array.isArray(msgs) ? msgs : msgs.messages || [];
  const people = readJSON(p("people.json"), {});
  const skip = config().exclude_drives || ["daktela"];   // Daktela stays separate here too
  for (const m of msgs) {
    if (skip.some((d) => String(m.folderPath || "").includes(d.replace(/\.com$/, "")))) continue;
    const from = String(m.author || m.from || "");
    const email = (from.match(/<([^>]+)>/) || [, from])[1].trim().toLowerCase();
    if (!email.includes("@")) continue;
    const e = people[email] || { email, name: from.replace(/<[^>]+>/, "").replace(/"/g, "").trim(), count: 0 };
    e.count++;
    const d = m.date ? new Date(m.date).toISOString() : undefined;
    if (!e.last_date || (d && d > e.last_date)) { e.last_date = d; e.last_subject = String(m.subject || "").slice(0, 160); }
    people[email] = e;
  }
  writeJSON(p("people.json"), people);
  return `${msgs.length} messages, ${Object.keys(people).length} people known`;
}

/** File list of every Google Drive account Brain may use (Spotlight doesn't index streamed Drive files). */
export function scanDrives() {
  const root = path.join(HOME, "Library/CloudStorage");
  const excluded = config().exclude_drives || ["daktela.com"];
  const files = [];
  if (!fs.existsSync(root)) return 0;
  for (const acct of fs.readdirSync(root).filter((d) => d.startsWith("GoogleDrive-") && !excluded.some((x) => d.includes(x)))) {
    const walk = (dir, depth) => {
      if (depth > 14) return;
      let entries; try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
      for (const e of entries) {
        if (e.name.startsWith(".")) continue;
        const f = path.join(dir, e.name);
        files.push({ path: f, folder: e.isDirectory() });
        if (e.isDirectory()) walk(f, depth + 1);
      }
    };
    for (const top of ["My Drive", "Shared drives"]) walk(path.join(root, acct, top), 0);
  }
  writeJSON(p("drive-index.json"), { at: new Date().toISOString(), files });
  return files.length;
}

export async function scanAll() {
  const report = {};
  status("Prechádzam projekty v ~/Developer");
  report.projects = await scanProjects();
  status("Záložky a Google Drive");
  report.bookmarks = scanBookmarks();
  report.drive_files = scanDrives();
  status("Pýtam sa MCP serverov na ich nástroje");
  const cache = await catalog.refresh();
  report.servers = Object.fromEntries(Object.entries(cache).map(([k, v]) => [k, v.error ? `error: ${v.error.slice(0, 80)}` : v.note ? "remote" : `${v.tools.length} tools`]));
  status("E-maily, Fathom meetingy, Todoist");
  if (config().digest.email) report.email = await digestEmail().catch((e) => `skipped: ${e.message}`);
  const mine = [];
  report.fathom = await fathom.importNew().then((r) => { mine.push(...r.action_items); return { written: r.written.length, skipped: r.skipped.length, your_action_items: r.action_items.length }; })
    .catch((e) => `skipped: ${e.message}`);
  // recaps shared by colleagues' Fathom accounts arrive by email (needs Thunderbird running)
  report.fathom_emails = await importRecapEmails().then((r) => { mine.push(...r.your_action_items); return { written: r.written.length, duplicates: r.duplicates.length }; })
    .catch((e) => `skipped: ${String(e.message).slice(0, 80)}`);
  // your action items from the newly imported meetings go straight to Todoist (auto_tasks in brain.config.json)
  report.todoist = await addMeetingTasks(mine).catch((e) => `skipped: ${String(e.message).slice(0, 80)}`);
  status("Čítam text z fotiek vo WhatsAppe");
  report.whatsapp_photos = await wa.ocrImages({ max: 300 }).catch((e) => `skipped: ${String(e.message).slice(0, 80)}`);
  if (beeper.connected()) report.messenger_photos = await beeper.ocrRecent({ max: 300 }).catch((e) => `skipped: ${String(e.message).slice(0, 80)}`);
  status("Ľudia a vyhľadávanie podľa významu");
  report.people = await buildPeople().catch((e) => `skipped: ${e.message}`);
  report.semantic = await buildIndex().catch((e) => `skipped: ${String(e.message).slice(0, 100)}`);   // incremental
  await closeAll();
  appendLine(p("usage.jsonl"), { event: "scan", report });
  writeJSON(p("last-scan.json"), { at: new Date().toISOString(), report });
  return report;
}
