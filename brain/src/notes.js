// What you told Brain: one Markdown file per fact in notes/, with frontmatter (id, date, topic, source, path).
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { NOTES } from "./paths.js";

const slug = (s) => s.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 50);
export const fold = (s) => String(s || "").toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");

function parse(file) {
  const raw = fs.readFileSync(file, "utf8");
  const m = raw.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
  const meta = {};
  if (m) for (const line of m[1].split("\n")) { const i = line.indexOf(":"); if (i > 0) meta[line.slice(0, i).trim()] = line.slice(i + 1).trim(); }
  return { ...meta, text: (m ? m[2] : raw).trim(), file };
}

export function all() {
  fs.mkdirSync(NOTES, { recursive: true });
  return fs.readdirSync(NOTES).filter((f) => f.endsWith(".md")).map((f) => parse(path.join(NOTES, f)));
}

/** Save a fact. A note with the same topic is replaced, so corrections don't pile up next to the old version. */
export function remember({ text, topic, source = "told by user", path: where }) {
  const id = crypto.randomBytes(3).toString("hex");
  const replaced = topic ? all().filter((n) => n.topic && fold(n.topic) === fold(topic)) : [];
  replaced.forEach((n) => fs.unlinkSync(n.file));
  const date = new Date().toISOString().slice(0, 10);
  const meta = { id, date, topic, source, path: where };
  const head = Object.entries(meta).filter(([, v]) => v).map(([k, v]) => `${k}: ${String(v).replace(/\n/g, " ")}`).join("\n");
  const file = path.join(NOTES, `${date}-${slug(topic || text)}-${id}.md`);
  fs.writeFileSync(file, `---\n${head}\n---\n${text.trim()}\n`);
  return { id, file, replaced: replaced.map((n) => n.id) };
}

/** Delete notes by id, or every note whose topic or text contains the query. */
export function forget({ id, query }) {
  const gone = all().filter((n) => (id && n.id === id) || (query && (fold(n.topic).includes(fold(query)) || fold(n.text).includes(fold(query)))));
  gone.forEach((n) => fs.unlinkSync(n.file));
  return gone.map((n) => ({ id: n.id, topic: n.topic, text: n.text.slice(0, 120) }));
}

export function recall(query, limit = 10) {
  const words = fold(query).split(/\s+/).filter(Boolean);
  return all()
    .map((n) => ({ n, score: words.filter((w) => fold(`${n.topic} ${n.text} ${n.path || ""}`).includes(w)).length }))
    .filter((x) => x.score > 0 || !words.length)
    .sort((a, b) => b.score - a.score || String(b.n.date).localeCompare(String(a.n.date)))
    .slice(0, limit)
    .map(({ n }) => ({ id: n.id, date: n.date, topic: n.topic, source: n.source, path: n.path, text: n.text }));
}
