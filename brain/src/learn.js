// Learning from use: every search is logged; opening or revealing a result shortly after links the query to that path.
import { p } from "./paths.js";
import { fold } from "./notes.js";
import { appendLine, readJSON, writeJSON } from "./store.js";

const LINKS = p("links.json");     // { "normalised query": { "/path": count } }
const RECENT = p("recent.json");   // last searches with their results, for linking
const WINDOW_MS = 15 * 60000;
const key = (q) => fold(q).replace(/\s+/g, " ").trim();

export function searched(query, paths) {
  appendLine(p("usage.jsonl"), { event: "where_is", query, results: paths.length });
  const recent = readJSON(RECENT, []).filter((r) => Date.now() - r.t < WINDOW_MS);
  recent.push({ t: Date.now(), q: key(query), paths });
  writeJSON(RECENT, recent.slice(-20));
}

/** Called when a path is opened/revealed/moved through Brain. Links it to recent searches that returned it. */
export function used(path) {
  const recent = readJSON(RECENT, []).filter((r) => Date.now() - r.t < WINDOW_MS && r.paths.includes(path));
  if (!recent.length) return;
  const links = readJSON(LINKS, {});
  for (const r of recent) { links[r.q] = links[r.q] || {}; links[r.q][path] = (links[r.q][path] || 0) + 1; }
  writeJSON(LINKS, links);
}

export function link(query, path) {
  const links = readJSON(LINKS, {});
  links[key(query)] = { ...(links[key(query)] || {}), [path]: 10 };
  writeJSON(LINKS, links);
}

/** Paths linked to this query or to a query sharing all its words. */
export function linksFor(query) {
  const k = key(query), words = k.split(" ");
  const scores = {};
  for (const [q, paths] of Object.entries(readJSON(LINKS, {}))) {
    if (q === k || words.every((w) => q.includes(w))) for (const [path, n] of Object.entries(paths)) scores[path] = (scores[path] || 0) + n;
  }
  return Object.entries(scores).sort((a, b) => b[1] - a[1]).slice(0, 3).map(([path]) => path);
}

export function log(event) { appendLine(p("usage.jsonl"), event); }
