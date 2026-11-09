// Fathom recap emails (e.g. meetings recorded on a colleague's Fathom account and shared with you) → the same
// Markdown meeting notes as the API import. Reads them from Courier (courier.search + courier.thread); summary and action
// items are translated into Slovak before they're written.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { folderFor, KUDOSKY_MEETINGS, resolveFolder, skipReason, taskFor } from "./fathom.js";
import { ICLOUD, p } from "./paths.js";
import { callTool, resultText } from "./pool.js";
import { appendLine, readJSON, writeJSON } from "./store.js";
import { toSlovak } from "./translate.js";

const COURIER_DB = path.join(os.homedir(), "Library/Application Support/Courier/courier.sqlite");   // Courier's local cache

const STATE = p("fathom-mail.json");   // { courier_seen: [Courier message ids] } (seen: the old Thunderbird ids)
const run = promisify(execFile);
const ME = ["kudosky", "matus", "matúš"];

const shareId = (s) => (s.match(/fathom\.video\/share\/([A-Za-z0-9_-]+)/) || [])[1];
const clean = (s) => String(s || "").replace(/[/:\\?*"<>|]/g, "-").replace(/\s+/g, " ").trim().slice(0, 90);

/** Parse one recap email's plain text (Courier's body_text). The text starts with the summary as plain Markdown, then the
 *  HTML part rendered as text: "Meeting with …", title, date, minutes, "Action Items" (task line, assignee line, …). */
export function parseRecap(body, sentAt, share) {
  const raw = String(body || "").replace(/\r/g, "").replace(/&bull;/g, "•").replace(/&amp;/g, "&").replace(/&nbsp;/g, " ");
  const lines = raw.split("\n").map((l) => l.trim());
  const meetingWith = lines.findIndex((l) => /^Meeting with /.test(l));
  const title = (meetingWith >= 0 && lines.slice(meetingWith + 1).find((l) => l)) || lines[meetingWith]?.replace(/^Meeting with /, "") || "Meeting";
  const dateLine = lines.find((l) => /^[A-Z][a-z]+ \d{1,2}, \d{4}/.test(l)) || "";
  const date = dateLine ? new Date(dateLine.replace(/\s*•.*/, "") + " 12:00").toISOString().slice(0, 10) : String(sentAt).slice(0, 10);
  const minutes = (lines.find((l) => /^\d+\s*mins?\b/.test(l)) || "").match(/\d+/)?.[0];
  const with_ = lines[meetingWith]?.replace(/^Meeting with /, "") || "";

  const actions = [];
  const aStart = lines.findIndex((l) => /^Action Items/.test(l)), sStart = lines.findIndex((l) => /^Meeting Summary/.test(l));
  if (aStart >= 0) {
    const block = lines.slice(aStart + 1, sStart > aStart ? sStart : undefined).filter(Boolean);
    for (let i = 0; i < block.length; i += 2) actions.push({ task: block[i], assignee: block[i + 1] || "" });
  }
  // the plain summary at the top, up to the HTML part ("Get your own FREE…" or "Meeting with …")
  const all = raw.split("\n");
  const stop = all.findIndex((l) => /^\s*(Get your own FREE|Meeting with )/.test(l));
  const summary = all.slice(0, stop > 0 ? stop : undefined).map((l) => l.trimEnd()).join("\n")
    .replace(/^\s+/, "").replace(/\n{3,}/g, "\n\n").trim();
  return { title, date, minutes, share, with: with_, actions, summary };
}

export function toMarkdown(r, recordedBy) {
  return [
    `# ${r.title}`, "",
    `- **Kedy:** ${r.date}${r.minutes ? ` (${r.minutes} min)` : ""}`,
    r.with ? `- **Účastníci:** ${r.with}` : null,
    `- **Nahraté:** Fathom (${recordedBy}), recap e-mail`,
    r.share ? `- **Fathom:** ${r.share}` : null,
    "", "## Zhrnutie", "", r.summary || "_Recap e-mail nemá zhrnutie._",
    r.actions.length ? ["", "## Úlohy", "", ...r.actions.map((a) => `- [ ] ${a.task}${a.assignee ? ` — ${a.assignee}` : ""}`)].join("\n") : null,
    "", `_Importoval Brain z recap e-mailu Fathomu ${new Date().toISOString().slice(0, 10)}._`, "",
  ].filter((x) => x !== null).join("\n");
}

/** Share ids already in meeting notes, so the same recording isn't saved twice. */
function knownShareIds() {
  const ids = new Set();
  const walk = (d) => { for (const e of fs.readdirSync(d, { withFileTypes: true })) {
    const f = path.join(d, e.name);
    if (e.isDirectory() && e.name !== "node_modules") walk(f);
    else if (e.name.endsWith(".md")) { const id = shareId(fs.readFileSync(f, "utf8").slice(0, 2000)); if (id) ids.add(id); }
  } };
  for (const d of [KUDOSKY_MEETINGS, ...["1.Kudosky/Meetings", "1.10T Studios/Meetings", "Meetings"].map((x) => path.join(ICLOUD, x))]) if (fs.existsSync(d)) walk(d);
  return ids;
}

const ask = async (tool, args) => {
  const r = await callTool("courier", tool, args, 60000);
  const t = resultText(r);
  if (r.isError) throw new Error(`Courier ${tool}: ${t.slice(0, 200)}`);
  return JSON.parse(t);
};

/** The Fathom share link from the HTML body in Courier's cache (the plain text has no links). */
async function shareFromCache(id) {
  if (!fs.existsSync(COURIER_DB)) return undefined;
  const { stdout } = await run("/usr/bin/sqlite3", ["-readonly", COURIER_DB,
    `SELECT substr(body_html, instr(body_html, 'fathom.video/share/'), 80) FROM messages WHERE id = ${Number(id)}`]).catch(() => ({ stdout: "" }));
  const sid = shareId(stdout);
  return sid ? `https://fathom.video/share/${sid}` : undefined;
}

/** The recap's text: courier.thread (the conversation, here one message), courier.read_message if the body isn't downloaded yet. */
async function recapText(id) {
  const thread = await ask("thread", { id: Number(id) }).catch(() => []);
  const msg = (Array.isArray(thread) ? thread : []).find((m) => m.id === Number(id) && m.text);
  return msg?.text || (await ask("read_message", { id: Number(id) })).text || "";
}

export async function importRecapEmails({ dry_run = false } = {}) {
  const found = await ask("search", { query: "recap of your meeting", limit: 200 });
  const recaps = (Array.isArray(found) ? found : []).filter((m) => /fathom\.video/i.test(m.from || "") && /recap of your meeting/i.test(m.subject || ""));
  const state = readJSON(STATE, { seen: [] });
  state.courier_seen ||= [];
  const known = knownShareIds();
  const report = { found: recaps.length, written: [], duplicates: [], skipped: [], already: 0, not_translated: [], your_action_items: [], daktela_action_items: [] };
  for (const m of recaps) {
    if (state.courier_seen.includes(m.id)) { report.already++; continue; }
    const body = await recapText(m.id);
    const r = parseRecap(body, m.date, await shareFromCache(m.id));
    const sharer = (m.subject.match(/^(?:\[SPAM\] )?(\S+) shared a recap/) || [])[1] || (r.with || "a colleague");
    const meeting = { title: r.title, calendar_invitees: (body.match(/[\w.+-]+@[\w-]+\.[\w.]+/g) || []).map((email) => ({ email })),
      default_summary: { markdown_formatted: r.summary } };
    const why = skipReason(meeting);
    if (why) { report.skipped.push({ title: r.title, why }); if (!dry_run) state.courier_seen.push(m.id); continue; }
    const sid = shareId(r.share || "");
    if (sid && known.has(sid)) { report.duplicates.push(`${r.date} ${r.title}`); if (!dry_run) state.courier_seen.push(m.id); continue; }
    // the same meeting already has a note (from the API, or from another attendee's recap): same date + title
    const folder = folderFor({ title: `${r.title} ${r.with} kudosky` });
    const file = path.join(resolveFolder(folder), `${r.date} ${clean(r.title)}.md`);
    if (fs.existsSync(file) || report.written.includes(file)) {
      report.duplicates.push(`${r.date} ${r.title}`);
      if (!dry_run) state.courier_seen.push(m.id);
      continue;
    }
    if (!dry_run) {
      // always into Slovak; if the translation fails the recap waits for the next run
      try {
        const sk = await toSlovak({ summary: r.summary, items: r.actions.map((a) => a.task) });
        r.summary = sk.summary;
        r.actions = r.actions.map((a, i) => ({ ...a, task: sk.items[i] }));
      } catch (e) { report.not_translated.push(`${r.date} ${r.title}: ${e.message}`); continue; }
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, toMarkdown(r, sharer));
      state.courier_seen.push(m.id);
      if (sid) known.add(sid);
    }
    report.written.push(file);
    const target = taskFor(meeting, undefined, folder);   // Kudosky, 10T, or Daktela (no Todoist)
    for (const a of r.actions) if (ME.some((x) => a.assignee.toLowerCase().includes(x)))
      report[target === "daktela" ? "daktela_action_items" : "your_action_items"].push({ date: r.date, meeting: r.title, task: a.task, target, context: `${r.with}\n${r.summary}`.slice(0, 6000) });
  }
  if (!report.not_translated.length) delete report.not_translated;
  if (!dry_run) { writeJSON(STATE, state); appendLine(p("usage.jsonl"), { event: "fathom_mail_import", written: report.written.length }); }
  return report;
}
