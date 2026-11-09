// Courier: the user's own mail app (com.lockedin.courier) with a local MCP server ("courier" in ~/.claude.json).
// Brain asks it for e-mail search and saving; everything stays on the Mac (Courier reads its local SQLite cache).
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { callTool, resultText } from "./pool.js";

const SERVER = "courier";
export const DB = path.join(os.homedir(), "Library/Application Support/Courier/courier.sqlite");
const run = promisify(execFile);

async function ask(tool, args, timeout = 30000) {
  const r = await callTool(SERVER, tool, args, timeout);
  const t = resultText(r);
  if (r.isError) throw new Error(`Courier ${tool}: ${t.slice(0, 200)}`);
  try { return JSON.parse(t); } catch { return t; }
}

/** Search in Courier (subject, people, text, attachment names), as Brain's mail shape: client "courier", id = Courier message id. */
export async function courierSearch(query, limit = 8) {
  const list = await ask("search", { query: query.replace(/"/g, "").trim(), limit });
  return (Array.isArray(list) ? list : []).map((m) => ({
    client: "courier", id: m.id, subject: m.subject, from: m.from, date: m.date, account: m.account, folder: m.folder,
    excerpt: m.snippet, group: m.group, attachments: m.attachments || undefined,
  }));
}

/** A whole Courier conversation as Markdown, plus its attachments, in one folder. */
export async function saveCourierEmail({ id, dir, put }) {
  const thread = await ask("thread", { id: Number(id) }, 60000);
  if (!Array.isArray(thread) || !thread.length) throw new Error(`Courier: správa ${id} sa nenašla`);
  const first = thread[0];
  const subject = first.subject || `e-mail ${id}`;
  const date = String(thread[thread.length - 1].date || "").slice(0, 10);
  const parts = [];
  const files = [];
  for (const m of thread) {
    const full = await ask("read_message", { id: m.id }, 60000);
    parts.push(`## ${full.from} — ${String(full.date).replace("T", " ").slice(0, 16)}\n\nKomu: ${full.to || ""}${full.cc ? `\nKópia: ${full.cc}` : ""}\n\n${full.text || ""}`);
    for (const [i, a] of (Array.isArray(full.attachments) ? full.attachments : []).entries()) {
      const r = await ask("save_attachment", { message_id: m.id, index: i, filename: a.filename, dir }, 120000);
      if (r?.path) files.push({ name: path.basename(r.path), path: r.path, bytes: fs.statSync(r.path).size });
    }
  }
  const md = put(dir, `${date ? date + " " : ""}${subject}.md`, `# ${subject}\n\n${parts.join("\n\n---\n\n")}\n`);
  return { md, files };
}

/** Mail for search by meaning straight from Courier's cache: mail from people (not newsletters or notifications) with a downloaded
 *  body or a preview, from inboxes, sent and archive folders, newer than `since`. Same shape as tools/mail.py prints. */
export async function courierMailForIndex(since, skipAccounts = []) {
  if (!fs.existsSync(DB)) return [];
  const sql = `SELECT m.message_id, m.subject, m.from_name, m.from_addr, m.to_line, m.date, coalesce(m.body_text, m.snippet, '') AS text,
      a.email AS account, m.folder FROM messages m JOIN accounts a ON a.id = m.account_id
    JOIN folders f ON f.account_id = m.account_id AND f.path = m.folder
    WHERE coalesce(m.category, 'people') = 'people' AND f.role IN ('inbox', 'sent', 'archive', 'other') AND m.date >= ${Math.floor(new Date(since).getTime() / 1000)}`;
  const { stdout } = await run("/usr/bin/sqlite3", ["-readonly", "-json", DB, sql], { maxBuffer: 1 << 28 });
  const rows = stdout.trim() ? JSON.parse(stdout) : [];
  return rows.filter((r) => !skipAccounts.some((x) => String(r.account).toLowerCase().includes(x))).map((r) => ({
    id: r.message_id ? `<${r.message_id}>` : `courier:${r.account}/${r.folder}/${r.date}`,
    account: r.account, folder: r.folder, date: new Date(r.date * 1000).toISOString().slice(0, 10),
    from: r.from_name || r.from_addr, from_email: String(r.from_addr || "").toLowerCase(), to: String(r.to_line || "").slice(0, 300),
    subject: String(r.subject || "").slice(0, 300),
    text: String(r.text || "").split("\n").filter((l) => !l.trimStart().startsWith(">")).join("\n").slice(0, 4000),
  }));
}

async function q(sql) {
  const { stdout } = await run("/usr/bin/sqlite3", ["-readonly", "-json", DB, sql], { maxBuffer: 1 << 26 });
  return stdout.trim() ? JSON.parse(stdout) : [];
}

const ago = (sec) => {
  const h = (Date.now() / 1000 - sec) / 3600;
  return h < 1 ? "pred chvíľou" : h < 24 ? `pred ${Math.round(h)} h` : `pred ${Math.round(h / 24)} d`;
};
const link = (id, text) => `[${String(text || "(bez predmetu)").replace(/[[\]]/g, "")}](courier://message/${id})`;

/** Morning brief section straight from Courier's cache (works with the app closed): unread conversations from people,
 *  open / waiting tickets, new invitations and invoices, scheduled and failed outgoing mail. */
export async function briefSection({ days = 3 } = {}) {
  if (!fs.existsSync(DB)) return { lines: [], counts: {} };
  const since = Math.floor(Date.now() / 1000) - days * 86400;
  const inbox = `m.folder IN (SELECT path FROM folders f WHERE f.account_id = m.account_id AND f.role = 'inbox')`;
  const override = `coalesce((SELECT category FROM sender_categories s WHERE s.address = lower(m.from_addr)), m.category, 'people')`;
  // newest unread message per conversation
  const unread = await q(`SELECT m.id, m.subject, m.from_name, m.from_addr, m.date, a.email AS account, ${override} AS cat
    FROM messages m JOIN accounts a ON a.id = m.account_id WHERE m.seen = 0 AND ${inbox} AND m.date >= ${since - 4 * 86400}
    AND m.id = (SELECT x.id FROM messages x WHERE x.account_id = m.account_id AND x.thread_id = m.thread_id ORDER BY x.date DESC LIMIT 1)
    ORDER BY m.date DESC LIMIT 200`);
  const people = unread.filter((m) => m.cat === "people" && m.date >= since);
  const invites = unread.filter((m) => m.cat === "invites");
  const invoices = unread.filter((m) => m.cat === "invoices");
  const tickets = await q(`SELECT t.status, m.id, m.subject, m.from_name, m.from_addr FROM tickets t
    JOIN messages m ON m.account_id = t.account_id AND m.thread_id = t.thread_id
    WHERE t.status IN ('open', 'waiting') AND m.id = (SELECT x.id FROM messages x WHERE x.account_id = t.account_id AND x.thread_id = t.thread_id ORDER BY x.date DESC LIMIT 1)
    ORDER BY m.date DESC`).catch(() => []);
  const outbox = await q(`SELECT message, send_at, error FROM outbox ORDER BY send_at`).catch(() => []);
  const accounts = new Set(people.map((m) => m.account)).size > 1;
  const who = (m) => m.from_name || m.from_addr;
  const L = [];
  if (people.length) {
    L.push(`**Pošta od ľudí, neprečítané (${people.length})**`,
      ...people.slice(0, 8).map((m) => `- **${who(m)}**: ${link(m.id, m.subject)} _(${ago(m.date)}${accounts ? ` · ${m.account}` : ""})_`),
      ...(people.length > 8 ? [`- … a ďalších ${people.length - 8} v Courieri`] : []), "");
  }
  const open = tickets.filter((t) => t.status === "open"), waiting = tickets.filter((t) => t.status === "waiting");
  if (open.length || waiting.length) {
    L.push(`**Tikety: ${open.length} otvorené, ${waiting.length} čaká sa**`,
      ...open.slice(0, 5).map((t) => `- ${link(t.id, t.subject)} _(${who(t)})_`), "");
  }
  if (invites.length) L.push(`**Pozvánky (${invites.length})**`, ...invites.slice(0, 5).map((m) => `- ${link(m.id, m.subject)} _(${who(m)})_`), "");
  if (invoices.length) L.push(`**Faktúry a platby (${invoices.length})**`, ...invoices.slice(0, 5).map((m) => `- ${link(m.id, m.subject)} _(${who(m)})_`), "");
  const today = new Date(); today.setHours(23, 59, 59, 999);
  const failed = outbox.filter((o) => o.error), planned = outbox.filter((o) => !o.error && o.send_at * 1000 <= today.getTime());
  const subj = (o) => { try { return JSON.parse(o.message).subject || "(bez predmetu)"; } catch { return "správa"; } };
  if (failed.length) L.push(`**Neodoslané (${failed.length})**`, ...failed.map((o) => `- ${subj(o)}: ${String(o.error).slice(0, 80)}`), "");
  if (planned.length) L.push(`**Dnes sa odošle (${planned.length})**`, ...planned.map((o) => `- ${new Date(o.send_at * 1000).toTimeString().slice(0, 5)} ${subj(o)}`), "");
  return { lines: L, counts: { mail_people: people.length, tickets_open: open.length, invites: invites.length, invoices: invoices.length, outbox_failed: failed.length } };
}
