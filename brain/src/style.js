// How the user writes: style/pisanie.md (the rules, editable by hand) plus the user's own latest messages in the same chat
// or e-mails to the same person, so a drafted text sounds like them there (casual in team chats, formal where it belongs).
import { execFile } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import * as beeper from "./beeper.js";
import { ROOT } from "./paths.js";
import * as wa from "./whatsapp.js";

const COURIER_DB = path.join(os.homedir(), "Library/Application Support/Courier/courier.sqlite");   // Courier's local cache

const run = promisify(execFile);
export const GUIDE = path.join(ROOT, "style/pisanie.md");
const SECTIONS = { chat: "## Správy – pracovné skupiny", formal_chat: "## Správy – cudzí", email: "## Maily", mailbox: "## Z ktorej schránky" };

/** The guide's sections for a channel (messages or e-mail), with the intro. */
export function guideFor(channel, text = fs.existsSync(GUIDE) ? fs.readFileSync(GUIDE, "utf8") : "") {
  const parts = text.split(/\n(?=## )/);
  const pick = (h) => parts.find((p) => p.startsWith(h)) || "";
  const keys = channel === "email" ? ["email", "mailbox"] : ["chat", "formal_chat"];
  return [parts[0], ...keys.map((k) => pick(SECTIONS[k]))].filter(Boolean).join("\n").trim();
}

const mine = (lines) => lines.filter((l) => l.split(" | ")[1] === "me").map((l) => l.split(" | ").slice(2).join(" | ")).filter((t) => t && !/^\[[a-z]+\]$/.test(t));

/** The user's own latest messages in a chat (WhatsApp, or a Beeper network). */
export async function chatExamples({ to, network = "whatsapp", limit = 15 }) {
  const r = network === "whatsapp" ? await wa.read({ chat: to, limit: 400 }) : await beeper.read({ chat: to, network, limit: 200, ocr: false });
  return { chat: r.chat, kind: r.kind, examples: mine(r.messages).slice(-limit) };
}

const sql = (s) => String(s).replace(/'/g, "''");

/** Body of a sent mail without the quoted part and the signature. */
export function ownPart(body) {
  const t = String(body || "").replace(/\r/g, "");
  const cut = t.search(/\n(?:On .{5,120}wrote:|Dňa .{5,160}napísal|Dne .{5,160}napsal|-----Original|From: |Od: |> )|\n-- ?\n|\nS pozdravom,?\s*\n\s*Ján Vzor\s*\n\s*Sales/);
  return (cut > 0 ? t.slice(0, cut) : t).replace(/\n{3,}/g, "\n\n").trim();
}

/** The user's latest sent e-mails to this address (or, with none, to the same domain), from Courier's cache. */
export async function emailExamples({ to, limit = 5 }) {
  if (!fs.existsSync(COURIER_DB) || !to) return { examples: [] };
  const addr = (String(to).match(/[\w.+-]+@[\w-]+\.[\w.-]+/) || [String(to)])[0].toLowerCase();
  const domain = addr.includes("@") ? addr.split("@")[1] : null;
  const query = (like) => run("/usr/bin/sqlite3", ["-readonly", "-json", COURIER_DB,
    `SELECT a.email AS account, m.to_line AS "to", m.subject, date(m.date, 'unixepoch') AS date, m.body_text AS body
     FROM messages m JOIN accounts a ON a.id = m.account_id JOIN folders f ON f.account_id = m.account_id AND f.path = m.folder
     WHERE f.role = 'sent' AND m.body_text IS NOT NULL AND lower(m.to_line) LIKE '%${sql(like)}%' ORDER BY m.date DESC LIMIT ${limit * 3}`],
    { maxBuffer: 1 << 26 }).then(({ stdout }) => (stdout.trim() ? JSON.parse(stdout) : []));
  let rows = await query(addr), match = "address";
  const common = /^(gmail|seznam|centrum|azet|zoznam|icloud|outlook|hotmail|yahoo|post)\./;
  if (!rows.length && domain && !common.test(domain)) { rows = await query("@" + domain); match = "domain"; }
  const seen = new Set();
  const examples = rows.map((r) => ({ date: r.date, from: r.account, to: String(r.to).slice(0, 80), subject: r.subject, text: ownPart(r.body).slice(0, 1200) }))
    .filter((e) => e.text && !seen.has(e.text) && seen.add(e.text)).slice(0, limit);
  return { match: examples.length ? match : "none", examples };
}

/** What writing_style returns: the rules for the channel and the user's own earlier texts to that chat or person. */
export async function writingStyle({ channel = "whatsapp", to } = {}) {
  const email = channel === "email";
  const out = { channel, guide: guideFor(email ? "email" : "chat"),
    how: "Write the draft the way the user writes there: match the tone, length, greeting, diacritics, language and slang of their own examples below; they outweigh the general rules. Never sound like an assistant." };
  if (!to) return out;
  try { Object.assign(out, email ? await emailExamples({ to }) : await chatExamples({ to, network: channel })); }
  catch (e) { out.examples = []; out.examples_error = String(e.message).slice(0, 160); }
  if (!out.examples?.length) out.note = email ? "No earlier mail to this person: first contact, use the guide (formal for strangers)." : "No earlier messages of the user in this chat: judge by who it is (team or friend → casual; stranger → polite).";
  return out;
}
