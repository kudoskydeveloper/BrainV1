// Search by meaning. Text from notes, meeting notes, documents and WhatsApp is cut into chunks, turned into vectors by a
// local model (Ollama, embeddinggemma) and kept in data/semantic. E-mails come straight from Thunderbird's local mbox files
// (tools/mail.py), the last mail_months, without Daktela/VinumVivo accounts, bulk mail, drafts, trash and junk. Nothing leaves the Mac. The index is incremental:
// a document is re-embedded only when it changed.
import { courierMailForIndex } from "./courier.js";
import { execFile } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { meetingFolders } from "./fathom.js";
import { prettyPath } from "./find.js";
import { all as allNotes, fold } from "./notes.js";
import { HOME, ICLOUD, NOTES, ROOT, p } from "./paths.js";
import { readFile } from "./read.js";
import { appendLine, config, readJSON, writeJSON } from "./store.js";
import * as wa from "./whatsapp.js";
import * as beeper from "./beeper.js";
import * as appleNotes from "./applenotes.js";
import { status } from "./ui.js";

const run = promisify(execFile);
const MAILPY = path.join(ROOT, "tools/mail.py");
const DIR = p("semantic");
const INDEX = path.join(DIR, "index.json");   // { model, docs: { key: { sig, source, title, ref, date, chunks: [text] } } }
const OLLAMA = "http://127.0.0.1:11434";
const DEFAULTS = { model: "embeddinggemma", max_file_mb: 15, max_pages: 30, whatsapp_months: 12, mail_months: 12,
  mail_skip_accounts: [], mail_folders: "^(INBOX|Sent.*|Archive?.*|\\d{4})$",
  folders: [ICLOUD, path.join(HOME, "Documents")] };
const settings = () => ({ ...DEFAULTS, ...(config().semantic || {}) });
const DOC_EXT = new Set(["pdf", "docx", "doc", "rtf", "odt", "pptx", "xlsx", "md", "txt"]);
const SKIP_DIR = /\/(node_modules|\.git|\.Trash|Library|_To delete|0\. Logins|Photos|MOMENTKA[^/]*|\.tmp)(\/|$)/;
const hash = (s) => crypto.createHash("sha1").update(s).digest("hex").slice(0, 16);

// ---- embedding -------------------------------------------------------------------------------------------------

export async function embed(texts, model = settings().model) {
  const out = [];
  for (let i = 0; i < texts.length; i += 32) {
    const r = await fetch(`${OLLAMA}/api/embed`, { method: "POST", body: JSON.stringify({ model, input: texts.slice(i, i + 32), truncate: true }),
                                                   signal: AbortSignal.timeout(120000) });
    if (!r.ok) throw new Error(`Ollama ${r.status}: ${(await r.text()).slice(0, 200)} (is Ollama running? brew services start ollama)`);
    out.push(...(await r.json()).embeddings);
  }
  return out.map((v) => { const n = Math.hypot(...v) || 1; return Float32Array.from(v, (x) => x / n); });
}

function chunk(text, size = 900, overlap = 150) {
  const t = text.replace(/[ \t]+/g, " ").replace(/\n{3,}/g, "\n\n").trim();
  if (t.length <= size) return t ? [t] : [];
  const out = [];
  for (let i = 0; i < t.length; i += size - overlap) {
    let end = Math.min(t.length, i + size);
    const br = t.lastIndexOf("\n", end);   // prefer cutting at a line break
    if (br > i + size * 0.6 && end < t.length) end = br;
    out.push(t.slice(i, end).trim());
    if (end >= t.length) break;
    i = end - (size - overlap);
  }
  return out.filter(Boolean);
}

// ---- documents to index -------------------------------------------------------------------------------------------

function walkFiles(root, s, out = []) {
  let entries; try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch { return out; }
  for (const e of entries) {
    if (e.name.startsWith(".") || e.name.startsWith("~$")) continue;   // hidden files and Office lock files
    const f = path.join(root, e.name);
    if (SKIP_DIR.test(f + "/") && !f.startsWith(path.join(HOME, "Library/CloudStorage")) && !f.startsWith(ICLOUD)) continue;
    if (/\/(node_modules|\.git|_To delete|0\. Logins|Photos|MOMENTKA[^/]*)(\/|$)/.test(f)) continue;
    if (e.isDirectory()) walkFiles(f, s, out);
    else if (DOC_EXT.has(path.extname(e.name).slice(1).toLowerCase())) out.push(f);
  }
  return out;
}

async function documentDocs(s, idx, report) {
  const files = s.folders.flatMap((d) => walkFiles(d, s));
  const docs = {};
  let n = 0;
  for (const f of files) {
    let st; try { st = fs.statSync(f); } catch { continue; }
    if (st.size > s.max_file_mb * 1048576 || st.size === 0) continue;
    if (st.blocks === 0) { report.cloud_only = (report.cloud_only || 0) + 1; continue; }   // iCloud/Drive placeholder: don't download it
    const key = "file:" + f, sig = `${st.size}:${Math.floor(st.mtimeMs)}`;
    if (idx.docs[key]?.sig === sig) { docs[key] = idx.docs[key]; continue; }   // unchanged
    if (++n % 100 === 0) status(`Dokumenty: prečítaných ${n} z ${files.length}`);
    if (n % 100 === 0) appendLine(p("usage.jsonl"), { event: "semantic_progress", read: n, of: files.length });
    try {
      const r = await readFile({ path: f, ocr: "off", pages: `1-${s.max_pages}`, max_chars: 120000 });
      if (!r.text || r.text.trim().length < 40) continue;
      const title = path.basename(f).replace(/\.[^.]+$/, "");
      docs[key] = { sig, source: meetingFolders().some((d) => f.startsWith(d + "/")) ? "meeting" : "file", title, ref: f, date: st.mtime.toISOString().slice(0, 10), chunks: chunk(r.text), fresh: true };
    } catch (e) { report.errors++; }
  }
  return docs;
}

async function appleNoteDocs() {
  const docs = {};
  for (const n of await appleNotes.refresh()) {
    if (n.text.trim().length < 30) continue;
    docs["anote:" + n.id] = { sig: hash(n.modified + n.text.length), source: "apple_note", title: `${n.name} (${n.folder})`, ref: `apple-note:${n.id}`,
                              date: n.modified, chunks: chunk(n.text) };
  }
  return docs;
}

function noteDocs() {
  const docs = {};
  for (const n of allNotes()) {
    docs["note:" + n.id] = { sig: hash(n.text + n.topic), source: "note", title: n.topic || n.text.slice(0, 60), ref: n.file, date: n.date, chunks: chunk(`${n.topic || ""}\n${n.text}`) };
  }
  return docs;
}

async function whatsappDocs(s, idx) {
  const docs = {};
  const chats = await wa.chats({ limit: 1000 });
  const since = new Date(Date.now() - s.whatsapp_months * 31 * 86400000).toISOString().slice(0, 10);
  for (const c of chats) {
    if (c.messages < 3 || c.last < since) continue;
    const r = await wa.read({ chat: String(c.id), since, limit: 2000 });
    const byMonth = {};
    for (const line of r.messages) (byMonth[line.slice(0, 7)] ||= []).push(line);
    for (const [month, lines] of Object.entries(byMonth)) {
      const key = `wa:${c.id}:${month}`, sig = `${lines.length}:${hash(lines[lines.length - 1])}`;
      docs[key] = idx.docs[key]?.sig === sig ? idx.docs[key]
        : { sig, source: "whatsapp", title: `${c.name} (${month})`, ref: `whatsapp:${c.name}`, date: lines[lines.length - 1].slice(0, 10),
            chunks: chunk(lines.join("\n"), 1200, 200), fresh: true };
    }
  }
  return docs;
}

/** Messenger chats (through Beeper) active within whatsapp_months, by month like WhatsApp. Skipped when Beeper isn't connected. */
async function messengerDocs(s, idx) {
  if (!beeper.connected()) return null;
  const docs = {};
  const since = new Date(Date.now() - s.whatsapp_months * 31 * 86400000).toISOString().slice(0, 10);
  for (const c of await beeper.chats({ limit: 200 })) {
    if (c.last < since) continue;
    const r = await beeper.read({ chat: c.id, limit: 500 });
    const byMonth = {};
    for (const line of r.messages) if (line.slice(0, 10) >= since) (byMonth[line.slice(0, 7)] ||= []).push(line);
    for (const [month, lines] of Object.entries(byMonth)) {
      const key = `fb:${c.id}:${month}`, sig = `${lines.length}:${hash(lines[lines.length - 1])}`;
      docs[key] = idx.docs[key]?.sig === sig ? idx.docs[key]
        : { sig, source: "messenger", title: `${c.name} (${month})`, ref: `messenger:${c.name}`, date: lines[lines.length - 1].slice(0, 10),
            chunks: chunk(lines.join("\n"), 1200, 200), fresh: true };
    }
  }
  return docs;
}

const MAILBOXES = path.join(DIR, "mailboxes.json");   // { "<mbox path>": "size:mtime" } as of the last index

/** Thunderbird's IMAP accounts and their mbox files worth indexing. */
export function mailboxes(s = settings()) {
  const profiles = path.join(HOME, "Library/Thunderbird/Profiles");
  let dirs; try { dirs = fs.readdirSync(profiles); } catch { return []; }
  const out = [];
  for (const d of dirs) {
    const prefs = (() => { try { return fs.readFileSync(path.join(profiles, d, "prefs.js"), "utf8"); } catch { return ""; } })();
    const acc = {};
    for (const [, n, k, v] of prefs.matchAll(/user_pref\("mail\.server\.(server\d+)\.(directory-rel|userName)", "([^"]*)"\);/g)) (acc[n] ||= {})[k] = v;
    for (const a of Object.values(acc)) {
      if (!a["directory-rel"]?.startsWith("[ProfD]ImapMail/") || !a.userName) continue;
      if (s.mail_skip_accounts.some((x) => a.userName.toLowerCase().includes(x))) continue;
      const root = path.join(profiles, d, a["directory-rel"].slice(7));
      const walk = (dir, prefix) => {
        let es; try { es = fs.readdirSync(dir, { withFileTypes: true }); } catch { return; }
        for (const e of es) {
          if (e.isDirectory() && e.name.endsWith(".sbd")) walk(path.join(dir, e.name), prefix + e.name.slice(0, -4) + "/");
          else if (e.isFile() && !e.name.includes(".") && new RegExp(s.mail_folders, "i").test(e.name)) out.push({ account: a.userName, folder: prefix + e.name, file: path.join(dir, e.name) });
        }
      };
      walk(root, "");
    }
  }
  return out;
}

async function mailDocs(s, idx) {
  const boxes = mailboxes(s);
  const before = readJSON(MAILBOXES, {}), now = {};
  const docs = {}, changed = [];
  for (const b of boxes) {
    let st; try { st = fs.statSync(b.file); } catch { continue; }
    now[b.file] = `${st.size}:${Math.floor(st.mtimeMs)}`;
    if (before[b.file] === now[b.file]) {   // unchanged: keep what was indexed from it
      for (const [k, v] of Object.entries(idx.docs)) if (k.startsWith("mail:") && v.box === b.file) docs[k] = v;
    } else changed.push(b);
  }
  if (changed.length) {
    status(`Čítam e-maily z ${changed.length} priečinkov Thunderbirdu`);
    const since = new Date(Date.now() - s.mail_months * 31 * 86400000).toISOString().slice(0, 10);
    const { stdout } = await run("python3", ["-I", MAILPY, "--since", since, ...changed.flatMap((b) => [b.account, b.folder, b.file])], { maxBuffer: 1 << 30, timeout: 900000 });
    const byFile = Object.fromEntries(changed.map((b) => [`${b.account}\u0000${b.folder}`, b.file]));
    for (const line of stdout.split("\n")) {
      if (!line) continue;
      const m = JSON.parse(line);
      const text = `${m.subject}\nOd: ${m.from} <${m.from_email}>\nKomu: ${m.to}\n\n${m.text}`;
      if (m.text.length < 20) continue;
      docs["mail:" + m.id] = { sig: hash(m.id), source: "email", box: byFile[`${m.account}\u0000${m.folder}`],
        title: `${m.subject || "(bez predmetu)"} — ${m.from}`, ref: `email:${m.account}/${m.folder}`, date: m.date, chunks: chunk(text).slice(0, 4) };
    }
  }
  // Courier's cache (the user's own mail app): mail from people, also from accounts Thunderbird no longer has.
  try {
    const since = new Date(Date.now() - s.mail_months * 31 * 86400000).toISOString().slice(0, 10);
    const list = await courierMailForIndex(since, s.mail_skip_accounts);
    if (list.length) status(`Čítam e-maily z Courieru (${list.length})`);
    for (const m of list) {
      if (m.text.length < 20 || docs["mail:" + m.id]) continue;
      const text = `${m.subject}\nOd: ${m.from} <${m.from_email}>\nKomu: ${m.to}\n\n${m.text}`;
      const sig = hash(m.id + m.text.length);
      docs["mail:" + m.id] = idx.docs["mail:" + m.id]?.sig === sig ? idx.docs["mail:" + m.id]
        : { sig, source: "email", box: "courier", title: `${m.subject || "(bez predmetu)"} — ${m.from}`, ref: `email:${m.account}/${m.folder}`,
            date: m.date, chunks: chunk(text).slice(0, 4) };
    }
  } catch (e) { status(`Courier: ${String(e.message || e).slice(0, 120)}`); }
  return { docs, save: () => writeJSON(MAILBOXES, now) };
}

// ---- build ---------------------------------------------------------------------------------------------------------

export async function buildIndex({ only } = {}) {
  const s = settings();
  fs.mkdirSync(path.join(DIR, "vec"), { recursive: true });
  const idx = readJSON(INDEX, { model: s.model, docs: {} });
  if (idx.model !== s.model) idx.docs = {};
  const report = { errors: 0 };
  const parts = {};
  status("Zbieram texty na indexovanie");
  if (!only || only === "notes") parts.notes = noteDocs();
  if (!only || only === "apple_notes") parts.apple_notes = await appleNoteDocs().catch((e) => { report.apple_notes_error = e.message; return null; });
  if (!only || only === "files") parts.files = await documentDocs(s, idx, report);
  let mail = null;
  if (!only || only === "email") { mail = await mailDocs(s, idx).catch((e) => { report.email_error = e.message.slice(0, 200); return null; }); parts.email = mail?.docs || null; }
  if (!only || only === "whatsapp") parts.whatsapp = await whatsappDocs(s, idx).catch((e) => { report.whatsapp_error = e.message; return null; });
  if (!only || only === "messenger") parts.messenger = await messengerDocs(s, idx).catch((e) => { report.messenger_error = e.message; return null; });
  const docs = only ? { ...idx.docs } : {};
  if (only) for (const k of Object.keys(docs)) if (k.startsWith({ notes: "note:", files: "file:", whatsapp: "wa:", messenger: "fb:", apple_notes: "anote:", email: "mail:" }[only])) delete docs[k];
  for (const part of Object.values(parts)) if (part) Object.assign(docs, part);
  if (!only && !parts.whatsapp) for (const [k, v] of Object.entries(idx.docs)) if (k.startsWith("wa:")) docs[k] = v;   // keep old WhatsApp if unreadable now
  if (!only && !parts.messenger) for (const [k, v] of Object.entries(idx.docs)) if (k.startsWith("fb:")) docs[k] = v;   // Beeper off: keep old Messenger
  if (!only && !parts.email) for (const [k, v] of Object.entries(idx.docs)) if (k.startsWith("mail:")) docs[k] = v;
  if (!only && !parts.apple_notes) for (const [k, v] of Object.entries(idx.docs)) if (k.startsWith("anote:")) docs[k] = v;

  let embedded = 0;
  status(`Prepočítavam zmenené dokumenty (z ${Object.keys(docs).length})`);
  for (const [key, d] of Object.entries(docs)) {
    const vf = path.join(DIR, "vec", hash(key) + ".f32");
    const stale = d.fresh || !fs.existsSync(vf) || idx.docs[key]?.sig !== d.sig;
    delete d.fresh;
    if (!stale || !d.chunks.length) continue;
    const vecs = await embed(d.chunks.map((c) => `${d.title}\n${c}`));
    fs.writeFileSync(vf, Buffer.concat(vecs.map((v) => Buffer.from(v.buffer))));
    embedded += d.chunks.length;
  }
  // drop vectors of documents that disappeared
  const keep = new Set(Object.keys(docs).map((k) => hash(k) + ".f32"));
  for (const f of fs.readdirSync(path.join(DIR, "vec"))) if (!keep.has(f)) fs.unlinkSync(path.join(DIR, "vec", f));
  writeJSON(INDEX, { model: s.model, built: new Date().toISOString(), docs });
  mail?.save();   // only after the vectors exist, so an interrupted run re-reads the changed mailboxes
  cache = null;
  const counts = {};
  for (const d of Object.values(docs)) counts[d.source] = (counts[d.source] || 0) + 1;
  const out = { docs: Object.keys(docs).length, by_source: counts, chunks: Object.values(docs).reduce((n, d) => n + d.chunks.length, 0), embedded_now: embedded, ...report };
  appendLine(p("usage.jsonl"), { event: "semantic_index", ...out });
  return out;
}

// ---- search --------------------------------------------------------------------------------------------------------

let cache = null;   // { built, docs: [[key, doc, Float32Array[]]] }
function load() {
  const idx = readJSON(INDEX, null);
  if (!idx) throw new Error("No semantic index yet. Run semantic_reindex (or wait for the daily scan).");
  if (cache?.built === idx.built) return cache;
  const docs = [];
  for (const [key, d] of Object.entries(idx.docs)) {
    const vf = path.join(DIR, "vec", hash(key) + ".f32");
    if (!fs.existsSync(vf)) continue;
    const buf = fs.readFileSync(vf), dim = buf.length / 4 / Math.max(1, d.chunks.length);
    const all = new Float32Array(buf.buffer, buf.byteOffset, buf.length / 4);
    docs.push([key, d, d.chunks.map((_, i) => all.subarray(i * dim, (i + 1) * dim))]);
  }
  cache = { built: idx.built, model: idx.model, docs };
  return cache;
}

export async function semanticSearch({ query, sources, limit = 10, min_score = 0.35 }) {
  const c = load();
  status(`Porovnávam s ${c.docs.length} dokumentmi${sources?.length ? ` (${sources.join(", ")})` : ""}`);
  const [q] = await embed([query], c.model);
  const hits = [];
  for (const [key, d, vecs] of c.docs) {
    if (sources?.length && !sources.includes(d.source)) continue;
    let best = -1, bi = 0;
    vecs.forEach((v, i) => { let s = 0; for (let j = 0; j < v.length; j++) s += v[j] * q[j]; if (s > best) { best = s; bi = i; } });
    if (best >= min_score) hits.push({ score: +best.toFixed(3), source: d.source, title: d.title, date: d.date,
      where: /^(whatsapp|messenger|apple-note|email):/.test(d.ref) ? d.ref : prettyPath(d.ref), excerpt: d.chunks[bi].slice(0, 400) });
  }
  return hits.sort((a, b) => b.score - a.score).slice(0, limit);
}

/** Exact words (case and diacritics ignored) in indexed documents of one source, newest first: e.g. every e-mail mentioning a client. */
export function textSearch({ query, source, limit = 15 }) {
  const c = load();
  const words = fold(query).split(/\s+/).filter((w) => w.length > 1);
  const res = words.map((w) => new RegExp(`(^|[^a-z0-9])${w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));   // from the start of a word
  const hits = [];
  for (const [, d] of c.docs) {
    if (source && d.source !== source) continue;
    // e-mails: subject and body only, so a client's name in the sender address (e.g. hello@klient.example) doesn't match every mail
    const all = d.source === "email" ? fold(`${d.title.split(" — ")[0]}\n${d.chunks.join("\n").replace(/^(Od|Komu): .*$/gm, "")}`)
                                     : fold(`${d.title}\n${d.chunks.join("\n")}`);
    if (!res.every((r) => r.test(all))) continue;
    const at = d.chunks.findIndex((ch) => fold(ch).includes(words[0]));
    hits.push({ source: d.source, title: d.title, date: d.date, where: /^(whatsapp|messenger|apple-note|email):/.test(d.ref) ? d.ref : prettyPath(d.ref),
                excerpt: d.chunks[Math.max(0, at)].slice(0, 300) });
  }
  return hits.sort((a, b) => String(b.date).localeCompare(String(a.date))).slice(0, limit);
}
