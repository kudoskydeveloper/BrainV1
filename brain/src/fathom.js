// Fathom → meeting notes. New recordings become Markdown files in iCloud (one per meeting, filed by business);
// their action items are returned so Claude can propose them as Todoist tasks. Meetings with skipped domains
// (Daktela by default) are never written anywhere. Several Fathom accounts can be read, each with its own API key:
// the second one (the phone's) files 10T meetings with 10T and everything else as private, judging by its summary too.
// Action items go to the Todoist of the business the meeting is about (taskFor); Daktela ones to none.
// Summary and action items are always translated into Slovak before the note is written (translate.js).
import fs from "node:fs";
import path from "node:path";
import { HOME, ICLOUD, p } from "./paths.js";
import { appendLine, config, readJSON, writeJSON } from "./store.js";
import { toSlovak } from "./translate.js";

const KEY_FILE = path.join(HOME, ".config/fathom/api_key");
const PRIVATE = "Meetings/Súkromné";
const API = "https://api.fathom.ai/external/v1";
const STATE = p("fathom.json");   // { last: ISO date of the newest imported meeting, seen: [ids] }
const NO_SUMMARY = "_Fathom zatiaľ nemá zhrnutie._";
const waitsForSummary = (note) => note?.includes(NO_SUMMARY) || note?.includes("_No summary from Fathom._");   // the older English marker too
// Fathom adds the summary a few minutes after a recording ends: a fresh recording without one waits for a later run,
// and a note written without a summary is rewritten once Fathom has it (recordings of the last RECHECK are looked at again).
const WAIT = 3 * 3600000, RECHECK = 2 * 86400000;

export const KUDOSKY_MEETINGS = path.join(HOME, "Library/CloudStorage/GoogleDrive-hello@firma2.example/My Drive/Meetings");   // example only
/** Folder rules are absolute paths or relative to iCloud Drive. */
export const resolveFolder = (f) => (path.isAbsolute(f) ? f : path.join(ICLOUD, f));
const pretty = (f) => f.replace(ICLOUD, "iCloud Drive").replace(/^.*\/CloudStorage\/GoogleDrive-([^/]+)/, "Google Drive ($1)");

const DEFAULTS = {
  skip_domains: [],
  // first rule whose words appear in the title or attendee emails decides the folder (relative to iCloud Drive)
  folders: [
    // set your own in brain.config.json → fathom.folders, e.g.
    // { "match": ["firma1", "klient a"], "folder": "Firma1/Meetings" }
  ],
  default_folder: "Meetings",
  // key_file: the account's API key; default_folder: where meetings matching no rule go; use_summary: match the rules
  // against the summary too (phone recordings often have no telling title or invitees)
  accounts: [
    { name: "hlavný", key_file: KEY_FILE },
    { name: "mobil", key_file: path.join(HOME, ".config/fathom/api_key_mobile"), default_folder: PRIVATE, use_summary: true },
  ],
  // meetings about Daktela (e.g. recorded on the Kudosky account, with no daktela.com attendee): no Todoist at all
  daktela_words: [],
  // action items assigned to these count as yours (proposed as Todoist tasks); the rest stay in the note only
  me: [],   // brain.config.json → fathom.me
};

const settings = () => ({ ...DEFAULTS, ...(config().fathom || {}) });

function key(file = KEY_FILE) {
  const k = fs.existsSync(file) ? fs.readFileSync(file, "utf8").trim() : "";
  if (!k) throw new Error(`Fathom API key missing in ${file}`);
  return k;
}

async function get(pathname, params = {}, keyFile = KEY_FILE) {
  const url = new URL(API + pathname);
  for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
  const r = await fetch(url, { headers: { "X-Api-Key": key(keyFile), Accept: "application/json" }, signal: AbortSignal.timeout(30000) });
  const body = await r.text();
  if (!r.ok) throw new Error(`Fathom ${r.status} on ${pathname}: ${body.slice(0, 300)}`);
  return JSON.parse(body);
}

/** All meetings since a date, newest pages first, with summary and action items. */
export async function meetings({ since, limit = 200, keyFile } = {}) {
  const out = [];
  let cursor;
  do {
    const page = await get("/meetings", { created_after: since, include_summary: true, include_action_items: true, cursor }, keyFile);
    out.push(...(page.items || []));
    cursor = page.next_cursor;
  } while (cursor && out.length < limit);
  return out;
}

const emails = (m) => [...(m.calendar_invitees || []).map((i) => i.email), m.recorded_by?.email].filter(Boolean).map((e) => e.toLowerCase());
const domainOf = (e) => e.split("@")[1] || "";

export function skipReason(m, s = settings()) {
  const hit = emails(m).find((e) => s.skip_domains.some((d) => domainOf(e) === d || domainOf(e).endsWith("." + d)));
  return hit ? `attendee/organiser ${hit}` : null;
}

export function folderFor(m, s = settings(), account = {}) {
  const summary = account.use_summary ? m.default_summary?.markdown_formatted || "" : "";
  const hay = `${m.title || m.meeting_title || ""} ${emails(m).join(" ")} ${summary}`.toLowerCase();
  return (s.folders.find((r) => r.match.some((w) => hay.includes(w.toLowerCase()))) || {}).folder || account.default_folder || s.default_folder;
}

/** Every folder meeting notes are filed in (absolute paths): Kudosky Drive, 10T, private, the default one. */
export function meetingFolders(s = settings()) {
  return [...new Set([...s.folders.map((r) => r.folder), s.default_folder, ...s.accounts.map((a) => a.default_folder).filter(Boolean)].map(resolveFolder))];
}

/** Meeting notes from all those folders, newest first: { date, title, folder, path }. */
export function recentMeetings({ days = 30, query, limit = 30 } = {}) {
  const since = new Date(Date.now() - days * 86400000).toISOString().slice(0, 10);
  const q = String(query || "").toLowerCase();
  const out = [];
  for (const dir of meetingFolders()) {
    let files; try { files = fs.readdirSync(dir); } catch { continue; }   // not created yet, or Drive not mounted
    for (const f of files.filter((x) => x.endsWith(".md"))) {
      const date = f.slice(0, 10), title = f.slice(11).replace(/\.md$/, "");
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date) || date < since) continue;
      if (q && !`${title} ${dir}`.toLowerCase().includes(q)) continue;
      out.push({ date, title, folder: pretty(dir), path: path.join(dir, f) });
    }
  }
  return out.sort((a, b) => b.date.localeCompare(a.date)).slice(0, limit);
}

/** Where the user's action items from a meeting in this folder go: Kudosky Todoist, 10T Todoist or Reminders. */
export function taskTarget(folder) {
  return folder === PRIVATE ? "personal" : /10T/.test(folder) ? "10t" : "kudosky";
}

/**
 * Which Todoist the user's action items go to. The Kudosky account records 10T and Daktela meetings too, so this is
 * judged by what the meeting is about, not by the account or folder: title and attendees (without the user's own
 * addresses) first, then which business the summary mentions most; with no hint it follows the folder.
 * "daktela" means the items go nowhere.
 */
export function taskFor(m, s = settings(), folder = folderFor(m, s)) {
  const topics = [{ target: "daktela", match: s.daktela_words }, ...s.folders.map((r) => ({ target: taskTarget(r.folder), match: r.match }))];
  const others = emails(m).filter((e) => !s.me.some((x) => e.includes(x.toLowerCase())));
  const head = `${m.title || m.meeting_title || ""} ${others.join(" ")}`.toLowerCase();
  const hit = topics.find((t) => t.match.some((w) => head.includes(w.toLowerCase())));
  if (hit) return hit.target;
  const summary = (m.default_summary?.markdown_formatted || "").toLowerCase();
  const count = (t) => t.match.reduce((n, w) => n + summary.split(w.toLowerCase()).length - 1, 0);
  const [best, next] = topics.map((t) => ({ target: t.target, n: count(t) })).sort((a, b) => b.n - a.n);
  return best.n > (next?.n || 0) ? best.target : taskTarget(folder);
}

const clean = (s) => String(s || "").replace(/[/:\\?*"<>|]/g, "-").replace(/\s+/g, " ").trim().slice(0, 90);

export function toMarkdown(m) {
  const title = m.title || m.meeting_title || "Meeting";
  const when = m.recording_start_time || m.scheduled_start_time || m.created_at || "";
  const people = (m.calendar_invitees || []).map((i) => `${i.name || i.email}${i.email ? ` <${i.email}>` : ""}`);
  const actions = (m.action_items || []).map((a) => `- [${a.completed ? "x" : " "}] ${a.description}${a.assignee?.name ? ` — ${a.assignee.name}` : ""}`);
  return [
    `# ${title}`, "",
    `- **Kedy:** ${when ? new Date(when).toLocaleString("sv-SE").slice(0, 16) : ""}`,   // Fathom gives UTC; the note shows local time
    people.length ? `- **Účastníci:** ${people.join(", ")}` : null,
    m.share_url || m.url ? `- **Fathom:** ${m.share_url || m.url}` : null,
    "", "## Zhrnutie", "", (m.default_summary?.markdown_formatted || NO_SUMMARY).trim(),
    actions.length ? ["", "## Úlohy", "", ...actions].join("\n") : null,
    "", `_Importoval Brain z Fathomu ${new Date().toISOString().slice(0, 10)}._`, "",
  ].filter((x) => x !== null).join("\n");
}

/** Import new meetings from every account that has a key. Returns what was written, what was skipped and the action items. */
export async function importNew({ since, dry_run = false } = {}) {
  const s = settings();
  const state = readJSON(STATE, { last: null, seen: [] });
  const report = { written: [], updated: [], waiting: [], skipped: [], already: 0, action_items: [], accounts: {} };
  for (const acc of s.accounts) {
    if (!fs.existsSync(acc.key_file)) { report.accounts[acc.name] = "no API key"; continue; }
    const lastKey = acc.key_file === KEY_FILE ? "last" : `last_${acc.name}`;   // the first account keeps the old field
    const recheck = new Date(Date.now() - RECHECK).toISOString();
    const from = since || (!state[lastKey] ? new Date(Date.now() - 30 * 86400000).toISOString() : state[lastKey] < recheck ? state[lastKey] : recheck);
    try {
      const n = report.written.length;
      await importAccount({ s, acc, state, lastKey, from, dry_run, report });
      report.accounts[acc.name] = { since: from, written: report.written.length - n };
    } catch (e) { report.accounts[acc.name] = `error: ${String(e.message).slice(0, 160)}`; }
  }
  if (!dry_run) { state.seen = state.seen.slice(-2000); writeJSON(STATE, state); appendLine(p("usage.jsonl"), { event: "fathom_import", written: report.written.length, updated: report.updated.length, skipped: report.skipped.length }); }
  for (const k of ["updated", "waiting"]) if (!report[k].length) delete report[k];
  return report;
}

async function importAccount({ s, acc, state, lastKey, from, dry_run, report }) {
  const list = await meetings({ since: from, keyFile: acc.key_file });
  for (const m of list) {
    const id = String(m.recording_id || m.id || m.url);
    const title = m.title || m.meeting_title || "Meeting";
    const why = skipReason(m, s);
    if (why) { report.skipped.push({ title, why }); continue; }   // nothing about it is stored
    const day = (m.recording_start_time || m.created_at || "").slice(0, 10);
    const folder = folderFor(m, s, acc);
    const file = path.join(resolveFolder(folder), `${day} ${clean(title)}.md`);
    const summary = m.default_summary?.markdown_formatted;
    let before = null;   // the note as written without a summary, now to be completed
    if (state.seen.includes(id)) {
      before = summary && fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
      if (!waitsForSummary(before)) { report.already++; continue; }
    } else if (!summary && Date.now() - new Date(m.created_at || 0).getTime() < WAIT) {
      report.waiting.push(`${title} (Fathom ešte nemá zhrnutie)`); continue;   // not seen: picked up by a later run
    }
    const items = m.action_items || [];
    let sk = { summary, items: items.map((a) => a.description) };   // dry_run shows the original text
    if (!dry_run) {
      try { sk = await toSlovak({ summary: summary || "", items: sk.items }); }
      catch (e) { (report.not_translated ||= []).push(`${title}: ${e.message}`); continue; }   // not seen: the next run tries again
    }
    const slovak = { ...m, default_summary: summary ? { ...m.default_summary, markdown_formatted: sk.summary } : m.default_summary,
      action_items: items.map((a, i) => ({ ...a, description: sk.items[i] })) };
    if (!dry_run) {
      if (before !== null || !fs.existsSync(file)) {
        fs.mkdirSync(path.dirname(file), { recursive: true });
        fs.writeFileSync(file, toMarkdown(slovak));
      }
      if (before === null) state.seen.push(id);
      if (!state[lastKey] || (m.created_at || "") > state[lastKey]) state[lastKey] = m.created_at;
    }
    report[before === null ? "written" : "updated"].push(pretty(file));
    const target = taskFor(m, s, folder);
    const context = `${emails(m).join(" ")}\n${sk.summary || ""}`.slice(0, 6000);   // lets autotasks pick the Todoist project
    for (const [i, a] of slovak.action_items.entries()) {
      // items the first version already had were handled then (written in Slovak, or in English before translation existed)
      if (a.completed || before?.includes(a.description) || before?.includes(items[i].description)) continue;
      const who = `${a.assignee?.name || ""} ${a.assignee?.email || ""}`.toLowerCase();
      const mine = !who.trim() || s.me.some((x) => who.includes(x.toLowerCase()));
      const list = !mine ? (report.others_action_items ||= []) : target === "daktela" ? (report.daktela_action_items ||= []) : report.action_items;
      list.push({ meeting: title, date: day, task: a.description, assignee: a.assignee?.name, target, folder: pretty(resolveFolder(folder)), context });
    }
  }
}
