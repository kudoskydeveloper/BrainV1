// where_is: Spotlight + the project map + bookmarks + notes + what Brain learned from earlier searches.
import { execFile } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { fold, recall } from "./notes.js";
import { HOME, ICLOUD, p } from "./paths.js";
import { FOLDERS, folderId, isOff } from "./map.js";
import { config, readJSON } from "./store.js";
import * as learn from "./learn.js";

const run = promisify(execFile);
const CLOUD = path.join(HOME, "Library/CloudStorage");   // Google Drive (and other File Provider) accounts
const SCOPES = [ICLOUD, path.join(HOME, "Documents"), path.join(HOME, "Desktop"), path.join(HOME, "Downloads"),
  path.join(HOME, "Developer"), path.join(HOME, "Archive"), path.join(HOME, "Pictures"), path.join(HOME, "Market briefs"), CLOUD];

/** "~/Library/CloudStorage/GoogleDrive-hello@firma2.example/My Drive/x" → "Google Drive (hello@firma2.example)/My Drive/x" */
export const prettyPath = (f) => f
  .replace(ICLOUD, "iCloud Drive")
  .replace(new RegExp(`^${CLOUD.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/GoogleDrive-([^/]+)`), "Google Drive ($1)")
  .replace(HOME, "~");
const NOISE = /\/(node_modules|\.git|\.build|\.next|dist|build|DerivedData|Pods|\.venv|__pycache__)\//;
// Drive accounts Brain leaves alone (brain.config.json "exclude_drives"); Daktela's stays out by default
const excludedDrive = (f) => (config().exclude_drives || ["daktela.com"]).some((d) => new RegExp(`/CloudStorage/GoogleDrive-[^/]*${d.replace(/[.]/g, "\\.")}/`).test(f + "/"));

async function mdfind(query, nameOnly) {
  const words = query.split(/\s+/).filter(Boolean).map((w) => w.replace(/["\\*]/g, ""));
  if (!words.length) return [];
  const q = nameOnly ? words.map((w) => `kMDItemFSName == "*${w}*"cdw`).join(" && ") : query;
  const offFolders = new Set(FOLDERS.filter(([n]) => isOff(folderId(n))).map(([, f]) => f));   // switched off in the Brain map
  const args = [...SCOPES.filter((s) => fs.existsSync(s) && !offFolders.has(s)).flatMap((s) => ["-onlyin", s]), q];
  try {
    const { stdout } = await run("mdfind", args, { timeout: 15000, maxBuffer: 8 << 20 });
    return stdout.split("\n").filter((l) => l && !NOISE.test(l + "/") && !excludedDrive(l));
  } catch { return []; }
}

function info(file) {
  try {
    const st = fs.statSync(file);
    return { path: prettyPath(file), full: file, kind: st.isDirectory() ? "folder" : "file",
             modified: st.mtime.toISOString().slice(0, 10), size: st.isDirectory() ? undefined : st.size };
  } catch { return null; }
}

export async function whereIs(query, limit = 12) {
  const q = fold(query);
  const learned = learn.linksFor(query).map((f) => ({ ...info(f), why: "you opened this for a similar search before" })).filter((x) => x.full);
  const notes = recall(query, 5).filter((n) => n.path || /(\/|~)/.test(n.text));
  const words = q.split(/\s+/).filter((w) => w.length > 1);
  const projects = readJSON(p("projects.json"), [])
    .filter((pr) => { const hay = fold(`${pr.name} ${pr.business} ${pr.remote} ${pr.summary}`).replace(/[-_.]/g, " "); return words.length && words.every((w) => hay.includes(w)); })
    .slice(0, 5).map((pr) => ({ path: pr.path.replace(HOME, "~"), full: pr.path, kind: "project", business: pr.business, remote: pr.remote, summary: pr.summary }));
  const bookmarks = readJSON(p("bookmarks.json"), []).filter((b) => q.split(" ").every((w) => fold(`${b.title} ${b.folder} ${b.url}`).includes(w))).slice(0, 5);

  // Google Drive: Spotlight doesn't index streamed files, so search Brain's own list from the last scan
  const driveHits = (readJSON(p("drive-index.json"), { files: [] }).files || [])
    .filter((f) => !excludedDrive(f.path) && words.length && words.every((w) => fold(path.basename(f.path)).includes(w)))
    .slice(0, limit).map((f) => f.path);
  const byName = [...driveHits, ...(await mdfind(query, true))];
  const byContent = byName.length >= limit ? [] : await mdfind(query, false);
  const seen = new Set(learned.map((x) => x.full));
  const files = [];
  for (const f of [...byName, ...byContent]) {
    if (seen.has(f)) continue;
    seen.add(f);
    const i = info(f);
    if (i) files.push({ ...i, why: byName.includes(f) ? "name" : "content" });
    if (files.length >= limit * 3) break;
  }
  // names before content, then folders, then newest
  files.sort((a, b) => (a.why === b.why ? 0 : a.why === "name" ? -1 : 1) || (a.kind === "folder" ? -1 : 0) - (b.kind === "folder" ? -1 : 0) || b.modified.localeCompare(a.modified));
  const result = { learned, notes, projects, bookmarks, files: files.slice(0, limit) };
  learn.searched(query, [...learned, ...projects, ...files].map((x) => x.full));
  return result;
}
