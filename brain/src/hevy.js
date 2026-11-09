// Hevy (workouts) through its public API (api.hevyapp.com, Hevy Pro). The API key comes from hevy.com/settings?developer;
// `brain hevy-key` takes it from the clipboard into data/hevy.json. Reads run straight away; creating routines, logging
// workouts and body measurements come back as proposals (actions.js) for the user's yes.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fold } from "./notes.js";
import { p } from "./paths.js";
import { readJSON, writeJSON } from "./store.js";

const BASE = "https://api.hevyapp.com";
const KEY = p("hevy.json");          // { api_key }
const TEMPLATES = p("hevy-templates.json");   // exercise templates cache { at, items }

async function api(path, { method = "GET", query, body } = {}) {
  const key = readJSON(KEY, {}).api_key;
  if (!key) throw new Error("Hevy isn't connected: copy the API key from hevy.com/settings?developer and run `node ~/Developer/brain/src/cli.js hevy-key`.");
  const url = new URL(BASE + path);
  for (const [k, v] of Object.entries(query || {})) if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
  const r = await fetch(url, { method, headers: { "api-key": key, accept: "application/json", ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(20000) });
  if (r.status === 401) throw new Error("Hevy refused the API key (Hevy Pro needed; check hevy.com/settings?developer).");
  if (!r.ok) throw new Error(`Hevy ${method} ${path}: ${r.status} ${(await r.text()).slice(0, 200)}`);
  return r.status === 204 ? {} : r.json();
}

/** Save the API key from the clipboard after checking it works. */
export async function saveKeyFromClipboard() {
  const key = (await promisify(execFile)("pbpaste")).stdout.trim();
  if (!/^[0-9a-f-]{36}$/i.test(key)) throw new Error("the clipboard doesn't hold a Hevy API key (a UUID from hevy.com/settings?developer)");
  writeJSON(KEY, { api_key: key });
  try { return { connected: true, user: (await api("/v1/user/info")).data?.name }; }
  catch (e) { writeJSON(KEY, {}); throw e; }
}

export const connected = () => !!readJSON(KEY, {}).api_key;

/** All exercise templates (built-in and custom), cached for a week. */
async function templates(refresh = false) {
  const c = readJSON(TEMPLATES, null);
  if (!refresh && c && Date.now() - c.at < 7 * 86400000) return c.items;
  const items = [];
  for (let page = 1; page < 200; page++) {
    const r = await api("/v1/exercise_templates", { query: { page, pageSize: 100 } }).catch(() => api("/v1/exercise_templates", { query: { page, pageSize: 10 } }));
    items.push(...(r.exercise_templates || []).map((t) => ({ id: t.id, title: t.title, type: t.type, muscle: t.primary_muscle_group, equipment: t.equipment, custom: t.is_custom })));
    if (page >= (r.page_count || 1)) break;
  }
  writeJSON(TEMPLATES, { at: Date.now(), items });
  return items;
}

/** An exercise by name (or template id): exact title, else the best partial match. */
export async function exercise(name) {
  const all = await templates();
  if (/^[0-9A-F]{8}$/i.test(name)) { const t = all.find((x) => x.id === name.toUpperCase()); if (t) return t; }
  const f = fold(name), words = f.split(/\s+/);
  const hit = all.find((t) => fold(t.title) === f) || all.filter((t) => words.every((w) => fold(t.title).includes(w))).sort((a, b) => a.title.length - b.title.length)[0];
  if (!hit) throw new Error(`no Hevy exercise matching "${name}"; try the English name, e.g. "Bench Press (Barbell)"`);
  return hit;
}

export async function searchExercises({ query, limit = 15 }) {
  const f = fold(query || "");
  return (await templates()).filter((t) => !f || fold(`${t.title} ${t.muscle} ${t.equipment}`).includes(f)).slice(0, limit);
}

const fmtSet = (s) => [s.type !== "normal" ? s.type : "", s.weight_kg != null ? `${s.weight_kg} kg` : "", s.reps != null ? `× ${s.reps}` : "",
  s.distance_meters ? `${s.distance_meters} m` : "", s.duration_seconds ? `${Math.round(s.duration_seconds / 60)} min` : "", s.rpe ? `RPE ${s.rpe}` : ""].filter(Boolean).join(" ");

function summary(w, full = false) {
  const min = Math.round((Date.parse(w.end_time) - Date.parse(w.start_time)) / 60000);
  const volume = (w.exercises || []).flatMap((e) => e.sets || []).reduce((s, x) => s + (x.weight_kg || 0) * (x.reps || 0), 0);
  return { id: w.id, title: w.title, date: String(w.start_time).slice(0, 16).replace("T", " "), minutes: min, volume_kg: Math.round(volume),
    exercises: (w.exercises || []).map((e) => full ? { exercise: e.title, notes: e.notes || undefined, sets: (e.sets || []).map(fmtSet) }
      : `${e.title}: ${(e.sets || []).length}× (${(e.sets || []).map(fmtSet).slice(0, 4).join(", ")}${(e.sets || []).length > 4 ? ", …" : ""})`),
    ...(full && w.description ? { description: w.description } : {}) };
}

/** Recent workouts (newest first), optionally only those with an exercise or title matching `search`, or from the last `days`. */
export async function workouts({ limit = 10, days, search } = {}) {
  const out = [], since = days ? Date.now() - days * 86400000 : 0, f = search && fold(search);
  for (let page = 1; page <= 30 && out.length < limit; page++) {
    const r = await api("/v1/workouts", { query: { page, pageSize: 10 } });
    for (const w of r.workouts || []) {
      if (since && Date.parse(w.start_time) < since) return { count: out.length, workouts: out };
      if (!f || fold(`${w.title} ${(w.exercises || []).map((e) => e.title).join(" ")}`).includes(f)) out.push(summary(w));
      if (out.length >= limit) break;
    }
    if (page >= (r.page_count || 1)) break;
  }
  return { count: out.length, workouts: out };
}

/** Workouts from the last `days` as Hevy returns them (every set), newest first: the fitness overview computes from these. */
export async function rawWorkouts({ days = 365 } = {}) {
  const out = [], since = Date.now() - days * 86400000;
  for (let page = 1; page <= 60; page++) {
    const r = await api("/v1/workouts", { query: { page, pageSize: 10 } });
    for (const w of r.workouts || []) { if (Date.parse(w.start_time) < since) return out; out.push(w); }
    if (page >= (r.page_count || 1)) break;
  }
  return out;
}

/** Exercise templates by id: { title, type, muscle, equipment }. */
export async function templatesById() { return Object.fromEntries((await templates()).map((t) => [t.id, t])); }

export async function workout({ id }) { return summary((await api(`/v1/workouts/${id}`)), true); }

/** Every set of one exercise over a period, with the best set and estimated 1RM (Epley) per workout. */
export async function exerciseHistory({ exercise: name, from, to }) {
  const t = await exercise(name);
  const r = await api(`/v1/exercise_history/${t.id}`, { query: { start_date: from, end_date: to } });
  const byWorkout = {};
  for (const s of r.exercise_history || []) (byWorkout[s.workout_id] ||= { date: String(s.workout_start_time).slice(0, 10), sets: [] }).sets.push(s);
  const rows = Object.values(byWorkout).sort((a, b) => a.date.localeCompare(b.date)).map((w) => {
    const e1rm = (s) => (s.weight_kg || 0) * (1 + (s.reps || 0) / 30);
    const best = w.sets.reduce((b, s) => (e1rm(s) > e1rm(b) ? s : b), w.sets[0]);
    return { date: w.date, sets: w.sets.map(fmtSet), best: fmtSet(best), e1rm_kg: Math.round(e1rm(best) * 10) / 10 };
  });
  return { exercise: t.title, sessions: rows.length, history: rows };
}

export async function routines() {
  const out = [];
  for (let page = 1; page <= 20; page++) {
    const r = await api("/v1/routines", { query: { page, pageSize: 10 } });
    out.push(...(r.routines || []).map((x) => ({ id: x.id, title: x.title, folder_id: x.folder_id, exercises: (x.exercises || []).map((e) => `${e.title} ${(e.sets || []).length}×`) })));
    if (page >= (r.page_count || 1)) break;
  }
  return out;
}

/** One routine in full (every planned set), by id or title. */
export async function routine({ routine: r }) {
  const id = await routineId(r);
  const x = (await api(`/v1/routines/${id}`)).routine;
  return { id: x.id, title: x.title, notes: x.notes, folder_id: x.folder_id,
           exercises: (x.exercises || []).map((e) => ({ exercise: e.title, rest_seconds: e.rest_seconds, notes: e.notes || undefined,
             sets: (e.sets || []).map((s) => ({ type: s.type, weight_kg: s.weight_kg, reps: s.reps, distance_meters: s.distance_meters ?? undefined, duration_seconds: s.duration_seconds ?? undefined })) })) };
}

async function routineId(r) {
  if (/^[0-9a-f-]{36}$/i.test(r)) return r;
  const all = await routines(), f = fold(r);
  const hit = all.find((x) => fold(x.title) === f) || all.find((x) => fold(x.title).includes(f));
  if (!hit) throw new Error(`no Hevy routine matching "${r}" (routines: ${all.map((x) => x.title).join(", ")})`);
  return hit.id;
}

export async function body({ limit = 10 } = {}) {
  const r = await api("/v1/body_measurements", { query: { page: 1, pageSize: Math.min(limit, 10) } });
  return r.body_measurements || r;
}

/** Exercises as the API wants them: names resolved to template ids, sets typed. */
async function resolve(exercises, withRest) {
  const out = [];
  for (const e of exercises) {
    const t = await exercise(e.exercise);
    out.push({ exercise_template_id: t.id, title: t.title, notes: e.notes ?? null, ...(withRest ? { rest_seconds: e.rest_seconds ?? 90 } : {}),
      sets: (e.sets || []).map((s) => ({ type: s.type || "normal", weight_kg: s.weight_kg ?? null, reps: s.reps ?? null,
        distance_meters: s.distance_meters ?? null, duration_seconds: s.duration_seconds ?? null })) });
  }
  return out;
}

const lines = (ex) => ex.map((e) => `- ${e.title}: ${e.sets.map(fmtSet).join(", ") || "bez sérií"}`).join("\n");

export async function planRoutine({ title, notes, folder_id, exercises }) {
  const ex = await resolve(exercises, true);
  return { action: { type: "hevy", op: "routine", body: { routine: { title, folder_id: folder_id ?? null, notes: notes ?? null,
             exercises: ex.map(({ title: _, ...x }) => x) } }, what: title },
           summary: `Hevy: nová rutina „${title}“\n${lines(ex)}` };
}

export async function planWorkout({ title, start, end, description, exercises }) {
  const ex = await resolve(exercises, false);
  const s = new Date(start), e = end ? new Date(end) : new Date(s.getTime() + 3600000);
  return { action: { type: "hevy", op: "workout", body: { workout: { title, description: description ?? null, start_time: s.toISOString(), end_time: e.toISOString(),
             is_private: false, exercises: ex.map(({ title: _, ...x }) => x) } }, what: title },
           summary: `Hevy: zapísať tréning „${title}“ ${s.toLocaleString("sk-SK")} (${Math.round((e - s) / 60000)} min)\n${lines(ex)}` };
}

/** Change a routine: its whole new exercise list (read it with hevy_routine, then add / swap / remove / change sets), title, notes. */
export async function planRoutineUpdate({ routine: r, title, notes, exercises }) {
  const cur = await routine({ routine: r });
  const ex = await resolve(exercises, true);
  const was = new Set(cur.exercises.map((e) => e.exercise)), now = new Set(ex.map((e) => e.title));
  const added = [...now].filter((t) => !was.has(t)), removed = [...was].filter((t) => !now.has(t));
  return { action: { type: "hevy", op: "routine_update", id: cur.id, body: { routine: { title: title ?? cur.title, notes: notes ?? cur.notes ?? null,
             exercises: ex.map(({ title: _, ...x }) => x) } }, what: cur.title },
           summary: `Hevy: upraviť rutinu „${cur.title}“${title && title !== cur.title ? ` → „${title}“` : ""}`
             + (added.length ? `\n+ ${added.join(", ")}` : "") + (removed.length ? `\n− ${removed.join(", ")}` : "") + `\nnovo:\n${lines(ex)}` };
}

/** Change a logged workout: the whole new exercise list (read it with hevy_workout), title, description, times. */
export async function planWorkoutUpdate({ id, title, description, start, end, exercises }) {
  const cur = await api(`/v1/workouts/${id}`);
  const ex = await resolve(exercises, false);
  return { action: { type: "hevy", op: "workout_update", id, body: { workout: { title: title ?? cur.title, description: description ?? cur.description ?? null,
             start_time: start ? new Date(start).toISOString() : cur.start_time, end_time: end ? new Date(end).toISOString() : cur.end_time,
             is_private: cur.is_private ?? false, exercises: ex.map(({ title: _, ...x }) => x) } }, what: cur.title },
           summary: `Hevy: upraviť tréning „${cur.title}“ (${String(cur.start_time).slice(0, 10)})\nnovo:\n${lines(ex)}` };
}

export function planExercise({ title, exercise_type = "weight_reps", equipment_category = "none", muscle_group, other_muscles = [] }) {
  return { action: { type: "hevy", op: "exercise", body: { exercise: { title, exercise_type, equipment_category, muscle_group, other_muscles } }, what: title },
           summary: `Hevy: nový vlastný cvik „${title}“ (${muscle_group}, ${equipment_category}, ${exercise_type})` };
}

export function planBody(m) {
  const fields = Object.entries(m).filter(([k, v]) => k !== "date" && v != null).map(([k, v]) => `${k} ${v}`).join(", ");
  return { action: { type: "hevy", op: "body", body: m, what: m.date }, summary: `Hevy: telesné miery ${m.date}: ${fields}` };
}

export async function exec(a) {
  if (a.op === "routine") return { created: "routine", routine: (await api("/v1/routines", { method: "POST", body: a.body })).routine?.[0]?.id ?? true };
  if (a.op === "workout") return { created: "workout", workout: (await api("/v1/workouts", { method: "POST", body: a.body })).workout?.[0]?.id ?? true };
  if (a.op === "routine_update") { await api(`/v1/routines/${a.id}`, { method: "PUT", body: a.body }); return { updated: "routine", id: a.id }; }
  if (a.op === "workout_update") { await api(`/v1/workouts/${a.id}`, { method: "PUT", body: a.body }); return { updated: "workout", id: a.id }; }
  if (a.op === "exercise") {
    const r = await api("/v1/exercise_templates", { method: "POST", body: a.body });
    writeJSON(TEMPLATES, null);   // the new exercise must show up in lookups
    return { created: "exercise", id: r.id ?? r.exercise_template?.id ?? true };
  }
  if (a.op === "body") {
    try { await api("/v1/body_measurements", { method: "POST", body: a.body }); }
    catch (e) { if (!/409/.test(e.message)) throw e; const { date, ...rest } = a.body; await api(`/v1/body_measurements/${date}`, { method: "PUT", body: rest }); }
    return { saved: "body_measurements", date: a.body.date };
  }
  throw new Error(`unknown Hevy op ${a.op}`);
}
