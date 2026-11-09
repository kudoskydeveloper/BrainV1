// Meetings for the Meetingy app (in Hangar): the Fathom notes Brain imported (parsed into sections) and the upcoming calendar
// meetings with other people, plus a normalized meeting prep for one of them; a recording can be moved to another
// business or put in the Trash (`brain meeting-move`, `brain meeting-delete`).
// `brain meetings [--days 90]` and `brain meeting-prep <event id>`.
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import * as calendar from "./calendar.js";
import { meetingPrep } from "./dossier.js";
import { meetingFolders, recentMeetings } from "./fathom.js";
import { fold } from "./notes.js";
import { config } from "./store.js";

const ME = [];   // brain.config.json → dossier.me;
const NOT_MEETINGS = "^(gym|active focus|blocker|blockviz|travel|obed|lunch)\\b";
const settings = () => ({ me: ME, not_meetings: NOT_MEETINGS, ...(config().dossier || {}) });
const isMe = (s) => { const f = fold(s); return settings().me.some((m) => f.includes(fold(m))); };
const day = (d) => d.toLocaleDateString("sv-SE");

/** "[text](url)" → "text", "**x**" stays (the app renders inline Markdown). */
const unlink = (s) => s.replace(/\[([^\]]*)\]\((https?:[^)]*)\)/g, "$1");

/** What a section is, whatever language Fathom wrote it in. */
function kindOf(title) {
  const t = fold(title);
  if (/purpose|ucel/.test(t)) return "purpose";
  if (/takeaway|zistenia|kluc/.test(t)) return "takeaways";
  if (/next step|dalsie kroky/.test(t)) return "next_steps";
  if (/action item|ulohy/.test(t)) return "action_items";
  if (/transcript|prepis/.test(t)) return "transcript";
  if (/^summary$|zhrnutie/.test(t)) return "summary";
  if (/topic|temy/.test(t)) return "topics";
  return "other";
}

/** A Brain meeting note (Markdown) → header fields and sections of bullet lines; the transcript is only counted. */
export function parseNote(text) {
  const lines = text.split("\n");
  const out = { title: "", when: null, minutes: null, people: [], fathom: null, recorded_on: null, sections: [], transcript_lines: 0 };
  let sec = null, sub = null;
  for (const raw of lines) {
    const line = raw.replace(/\s+$/, "");
    if (!out.title && line.startsWith("# ")) { out.title = line.slice(2).trim(); continue; }
    const field = !out.sections.length && line.match(/^- \*\*(.+?):\*\*\s*(.*)$/);
    if (field) {
      const [, k, v] = field, key = fold(k);
      if (/when|kedy/.test(key)) {
        out.when = v.match(/\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2})?/)?.[0] ?? v;
        const m = v.match(/(\d+)\s*min/); if (m) out.minutes = Number(m[1]);
      } else if (/attendees|with|ucastnici/.test(key)) {
        out.people = v.split(/,\s*(?![^<]*>)/).map((p) => {
          const m = p.match(/^(.*?)\s*<([^>]+)>$/);
          return m ? { name: m[1].trim(), email: m[2].trim() } : { name: p.trim(), email: null };
        }).filter((p) => (p.name || p.email) && !isMe(`${p.name} ${p.email || ""}`));
      } else if (/fathom/.test(key)) out.fathom = v.match(/https?:\S+/)?.[0] ?? null;
      else if (/recorded|nahrat/.test(key)) out.recorded_on = unlink(v);
      continue;
    }
    if (line.startsWith("## ")) {
      const title = line.slice(3).trim();
      sec = { title, kind: kindOf(title), items: [] };
      sub = null;
      out.sections.push(sec);
      continue;
    }
    if (!sec) continue;
    if (/^_Import(ed|oval) .*Brain/.test(line)) continue;
    if (sec.kind === "transcript") { if (line.trim()) out.transcript_lines++; continue; }
    if (line.startsWith("### ")) { sub = line.slice(4).trim(); sec.items.push({ heading: sub }); continue; }
    if (/^_Import(ed|oval) .*Brain/.test(line) || !line.trim()) continue;
    const bullet = line.match(/^(\s*)[-*]\s+(?:\[( |x)\]\s+)?(.*)$/);
    if (bullet) {
      sec.items.push({ text: unlink(bullet[3]).trim(), indent: bullet[1].length, ...(bullet[2] ? { done: bullet[2] === "x" } : {}) });
    } else if (sec.items.length && sec.items.at(-1).text && /^\s{2,}\S/.test(line)) {
      sec.items.at(-1).text += " " + unlink(line.trim());   // a bullet continued on the next line
    } else {
      sec.items.push({ text: unlink(line.trim()), depth: 0, para: true });
    }
  }
  // depth from indentation, relative to each section's own levels (Fathom indents even its top bullets)
  for (const s of out.sections) {
    const levels = [...new Set(s.items.filter((i) => i.indent != null).map((i) => i.indent))].sort((a, b) => a - b);
    for (const i of s.items) if (i.indent != null) { i.depth = Math.min(2, levels.indexOf(i.indent)); delete i.indent; }
  }
  // Fathom's own "## Summary" is just a heading over the next sections
  out.sections = out.sections.filter((s) => s.kind !== "transcript" && (s.items.length || s.kind !== "summary"));
  return out;
}

const business = (folder) => /Súkromné|Sukromne/i.test(folder) ? "personal" : /10T/.test(folder) ? "10t" : /Kudosky/i.test(folder) ? "kudosky" : "other";
const JOIN = /(https:\/\/(?:meet\.google\.com\/[a-z-]+|[\w.-]*zoom\.us\/j\/[^\s"<>]+|teams\.microsoft\.com\/l\/meetup-join\/[^\s"<>]+|teams\.live\.com\/meet\/[^\s"<>]+))/i;

export async function overview({ days = 90, ahead = 14 } = {}) {
  const sources = {};
  const recordings = recentMeetings({ days, limit: 500 }).map((m) => {
    try {
      const text = fs.readFileSync(m.path, "utf8");
      const n = parseNote(text);
      return { ...m, business: business(m.folder), ...n, title: n.title || m.title };
    } catch (e) { return { ...m, business: business(m.folder), error: String(e.message).slice(0, 120), sections: [], people: [] }; }
  });
  sources.fathom = { ok: true };

  let upcoming = [];
  try {
    const { events } = await calendar.events({ from: day(new Date()), days: ahead, limit: 500 });
    const skip = new RegExp(settings().not_meetings, "i");
    const now = Date.now();
    upcoming = events
      .filter((e) => !e.all_day && !skip.test(fold(e.title || "")) && Date.parse(e.end) > now)
      .map((e) => {
        const people = (e.attendees || []).filter((a) => !isMe(`${a.name} ${a.email || ""}`))
          .map((a) => ({ name: a.name && a.name !== a.email ? a.name : "", email: a.email || null, status: a.status ?? null }));
        const join = `${e.location || ""}\n${e.notes || ""}`.match(JOIN)?.[1] ?? null;
        return { id: e.id, title: (e.title || "").trim(), start: e.start, end: e.end, calendar: e.calendar, account: e.account,
          location: e.location && !/^https?:/.test(e.location) ? e.location : null, join_url: join, people };
      })
      .filter((e) => e.people.length)
      .sort((a, b) => a.start.localeCompare(b.start));
    sources.calendar = { ok: true };
  } catch (e) { sources.calendar = { ok: false, error: String(e.message || e).slice(0, 200) }; }

  return { generated_at: new Date().toISOString(), days, sources, upcoming, recordings };
}

const pick = (x, ...keys) => { for (const k of keys) if (x?.[k] != null && x[k] !== "") return x[k]; return null; };
/** Anything list-like from meetingPrep → [{ title, detail, date, url }]; a part that failed → []. */
function rows(list, map) { return Array.isArray(list) ? list.map(map).filter((r) => r.title) : []; }

/** Meeting prep for one calendar event, in a shape the app can show without guessing. */
export async function prep({ id }) {
  const p = await meetingPrep({ id });
  return {
    meeting: p.meeting,
    companies: p.companies || [],
    people: (p.people || []).map((x) => ({
      name: x.name || x.crm?.[0]?.name || "", email: x.email || null, company: x.crm?.[0]?.account || x.company || null,
      crm: (x.crm || []).map((c) => ({ name: c.name, account: c.account })),
      emails: rows(x.emails, (m) => ({ title: pick(m, "subject", "title"), detail: pick(m, "from"), date: pick(m, "date") })).slice(0, 5),
      whatsapp: rows(x.whatsapp, (w) => ({ title: pick(w, "text", "body", "chat", "title"), detail: pick(w, "chat", "from"), date: pick(w, "date", "time") })).slice(0, 5),
    })),
    earlier: rows(p.earlier_meetings, (e) => ({ title: pick(e, "title"), detail: pick(e, "calendar"), date: pick(e, "start") })),
    notes: rows(p.notes_and_recordings, (n) => ({ title: pick(n, "title", "name"), detail: pick(n, "source", "snippet", "folder"), date: pick(n, "date", "modified"), path: pick(n, "path") })),
    emails: rows(p.related_emails, (m) => ({ title: pick(m, "subject", "title"), detail: pick(m, "from"), date: pick(m, "date"), client: pick(m, "client"), id: pick(m, "id") == null ? null : String(pick(m, "id")) })),
    tasks: rows(p.open_tasks, (t) => ({ title: pick(t, "content", "title"), detail: pick(t, "project", "account"), date: pick(t, "due", "dueDate") })),
  };
}

/** The folder recordings of a business are filed in (absolute), from Brain's Fathom folder rules. */
export function folderOf(biz) {
  return meetingFolders().find((f) => business(f) === biz) || null;
}

/** A note path Brain filed (inside one of the meeting folders), else an error. */
function ownNote(file) {
  // Swift hands paths over decomposed (NFD: "Súkromné" as u + ´), Brain's folder rules are composed (NFC)
  const f = path.resolve(String(file || "").normalize("NFC"));
  if (!f.endsWith(".md") || !meetingFolders().some((d) => d.normalize("NFC") === path.dirname(f))) throw new Error(`Nie je to poznámka z meetingov: ${f}`);
  if (!fs.existsSync(f)) throw new Error(`Poznámka už neexistuje: ${f}`);
  return f;
}

/** `brain meeting-move <path> <10t|kudosky|personal|other>`: moves a recording's note to another business's folder.
 *  Brain's Fathom import doesn't write it back (the recording is already "seen"). */
export function move({ file, to }) {
  const from = ownNote(file);
  const dir = folderOf(to);
  if (!dir) throw new Error(`Neznámy projekt: ${to}`);
  if (path.dirname(from) === dir.normalize("NFC")) return { path: from, business: to, moved: false };
  fs.mkdirSync(dir, { recursive: true });
  let dest = path.join(dir, path.basename(from));
  for (let i = 2; fs.existsSync(dest); i++) dest = path.join(dir, path.basename(from, ".md") + ` (${i}).md`);
  try { fs.renameSync(from, dest); }
  catch (e) { if (e.code !== "EXDEV") throw e; fs.copyFileSync(from, dest); fs.unlinkSync(from); }   // iCloud ↔ Google Drive
  return { path: dest, business: to, moved: true };
}

/** `brain meeting-delete <path>`: moves a recording's note to the Trash (Finder can put it back). */
export function remove({ file }) {
  const f = ownNote(file);
  const r = spawnSync("osascript", ["-e", "on run a", "-e", "tell application \"Finder\" to delete (POSIX file (item 1 of a) as alias)", "-e", "end run", f], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`Do Koša sa nepodarilo presunúť: ${(r.stderr || "").trim()}`);
  return { path: f, deleted: true };
}
