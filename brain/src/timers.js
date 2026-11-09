// Brain app timers, seen from the MCP side. The app owns them (timers.json, it fires them); we read that file to list them
// and talk to the app through brain:// URLs to add or cancel one, then read the file again to check it really happened.
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";

export const FILE = process.env.BRAIN_TIMERS_FILE || path.join(os.homedir(), "Library/Application Support/Brain/timers.json");

/** Older timers were sent with "+" for spaces (URLSearchParams) and the app kept them literally. */
export const clean = (s) => (s && !s.includes(" ") && s.includes("+") ? s.replace(/\+/g, " ") : s || "");

/** Query string the app's URLComponents reads back exactly: %20 for spaces, never "+". */
export function url(host, params) {
  const q = Object.entries(params).filter(([, v]) => v !== undefined && v !== null && v !== "")
    .map(([k, v]) => `${k}=${encodeURIComponent(String(v))}`).join("&");
  return `brain://${host}${q ? "?" + q : ""}`;
}

const fmt = (d) => new Date(d).toLocaleString("sk-SK", { weekday: "short", day: "numeric", month: "numeric", hour: "2-digit", minute: "2-digit" });

export function list(file = FILE) {
  let jobs = [];
  try { jobs = JSON.parse(fs.readFileSync(file, "utf8")); } catch { return []; }
  return jobs.sort((a, b) => new Date(a.at) - new Date(b.at)).map((j, i) => ({
    n: i + 1, id: j.id, when: fmt(j.at), at: j.at, task: clean(j.prompt),
    mode: j.remind ? "remind" : j.approved ? "do it (approved)" : "ask",
    ...(j.every ? { every_minutes: Math.round(j.every / 60), until: fmt(j.until), runs: j.runs || 0 } : {}),
  }));
}

/** Which timers `what` means: number from the list, id (or its start), or words from the task. */
export function match(jobs, what) {
  const w = String(what).trim().toLowerCase();
  if (/^\d{1,3}$/.test(w)) return jobs.filter((j) => j.n === Number(w));
  const byId = jobs.filter((j) => j.id.toLowerCase().startsWith(w));
  if (w.length >= 4 && byId.length) return byId;
  const words = w.split(/\s+/).filter(Boolean);
  return jobs.filter((j) => words.every((x) => j.task.toLowerCase().includes(x)));
}

const open = (u) => promisify(execFile)("open", ["-g", u]);
const settle = async (ok, file, ms = 3000) => {
  for (let t = 0; t < ms; t += 250) { if (ok(list(file))) return true; await new Promise((r) => setTimeout(r, 250)); }
  return ok(list(file));
};

export async function schedule({ task, seconds, from, approved, remind, every, until }, file = FILE) {
  const id = randomUUID().toUpperCase();
  await open(url("timer", { id, in: seconds, q: task, from, approved: approved ? 1 : undefined, remind: remind ? 1 : undefined,
    every, until: until && until.toISOString().replace(/\.\d+Z$/, "Z") }));
  const saved = await settle((jobs) => jobs.some((j) => j.id === id), file);
  return { id, saved };
}

export async function cancel({ which, all }, file = FILE) {
  const jobs = list(file);
  if (!jobs.length) return { cancelled: [], note: "No timers are set." };
  if (!which && !all) return { cancelled: [], timers: jobs, note: "Say which timer (n, id or words from its task), or all: true." };
  const hit = which ? match(jobs, which) : jobs;
  if (!hit.length) return { cancelled: [], timers: jobs, note: `No timer matches "${which}". Pick one by its n or id.` };
  if (hit.length > 1 && !all) return { cancelled: [], ambiguous: hit, note: "Several timers match: ask the user which one (by n), or pass all: true only if they want all of these gone." };
  for (const j of hit) await open(url("timer-cancel", { id: j.id }));
  const gone = await settle((now) => hit.every((j) => !now.some((x) => x.id === j.id)), file);
  return { cancelled: hit.map(({ n, when, task }) => ({ n, when, task })), verified: gone, left: list(file),
    ...(gone ? {} : { note: "The Brain app did not confirm it (is it running?). Tell the user to check with /timer." }) };
}
