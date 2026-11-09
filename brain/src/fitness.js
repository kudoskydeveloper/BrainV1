// One fitness overview from Hevy (strength, body weight), Strava (every recorded activity) and MyFitnessPal (food).
// Used by the MCP tool fitness_overview, `brain fitness --days N` and the Fitness app (in Hangar).
// A source that fails or isn't connected is reported in `sources` and the rest still comes back.
import * as hevy from "./hevy.js";
import * as strava from "./strava.js";
import { callTool, resultText } from "./pool.js";

const pad = (n) => String(n).padStart(2, "0");
const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const local = (iso) => { const d = new Date(iso); return `${ymd(d)} ${pad(d.getHours())}:${pad(d.getMinutes())}`; };
const round = (x, p = 1) => (x == null || Number.isNaN(x) ? null : Math.round(x * 10 ** p) / 10 ** p);
const avg = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null);
const sum = (xs, f) => xs.reduce((s, x) => s + (f(x) || 0), 0);

/** Monday (local) of the week a "YYYY-MM-DD…" date falls in, as YYYY-MM-DD. */
export function weekOf(date) {
  const d = new Date(`${String(date).slice(0, 10)}T12:00:00`);
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7));
  return ymd(d);
}

/** Which sport an activity is: strength, ride, run, swim, walk or other. */
export function sportOf(type) {
  const t = String(type || "");
  if (/Weight|Workout|Crossfit|Strength|Hiit/i.test(t)) return "strength";
  if (/Ride|Cycl|Velo/i.test(t)) return "ride";
  if (/Run/i.test(t)) return "run";
  if (/Swim/i.test(t)) return "swim";
  if (/Walk|Hike/i.test(t)) return "walk";
  return "other";
}
export const SPORTS = ["strength", "ride", "run", "swim", "walk", "other"];

/** Epley estimate of the one-rep max. */
export const e1rm = (kg, reps) => (kg > 0 && reps > 0 ? kg * (1 + (reps === 1 ? 0 : reps / 30)) : 0);

/** "1:05" (h:mm) → 65 */
const minutes = (hm) => { const [h, m] = String(hm || "0:00").split(":").map(Number); return (h || 0) * 60 + (m || 0); };

async function mfp(tool, args) {
  const text = resultText(await callTool("myfitnesspal", tool, args, 45000));
  try { return JSON.parse(text); } catch { throw new Error(text.slice(0, 200)); }
}

async function settle(name, fn, sources) {
  try { const v = await fn(); sources[name] = { ok: true }; return v; }
  catch (e) { sources[name] = { ok: false, error: String(e.message || e).slice(0, 200) }; return null; }
}

/** Per exercise, per workout: top set, estimated 1RM, volume. Over the whole Hevy history fetched (a year), newest workout first in. */
export function exerciseProgress(raw, templates = {}) {
  const by = new Map();
  for (const w of [...raw].sort((a, b) => a.start_time.localeCompare(b.start_time))) {
    for (const e of w.exercises || []) {
      const sets = (e.sets || []).filter((s) => s.type !== "warmup");
      if (!sets.length) continue;
      const t = templates[e.exercise_template_id] || {};
      const x = by.get(e.title) || by.set(e.title, { name: e.title, muscle: t.muscle || null, equipment: t.equipment || null, kind: null, history: [] }).get(e.title);
      const weighted = sets.some((s) => s.weight_kg > 0);
      const timed = !weighted && sets.some((s) => s.duration_seconds > 0) && !sets.some((s) => s.reps > 0);
      x.kind ||= weighted ? "weight" : timed ? "duration" : "reps";
      const top = sets.reduce((b, s) => (e1rm(s.weight_kg, s.reps) > e1rm(b.weight_kg, b.reps) || (!weighted && (s.reps || 0) > (b.reps || 0)) ? s : b), sets[0]);
      x.history.push({
        date: local(w.start_time).slice(0, 10), workout: w.title,
        sets: sets.length,
        reps: sum(sets, (s) => s.reps),
        top_kg: weighted ? round(Math.max(...sets.map((s) => s.weight_kg || 0))) : null,
        best_set: { kg: top.weight_kg ?? null, reps: top.reps ?? null, seconds: top.duration_seconds ?? null },
        e1rm_kg: weighted ? round(e1rm(top.weight_kg, top.reps)) : null,
        max_reps: Math.max(...sets.map((s) => s.reps || 0)) || null,
        volume_kg: Math.round(sum(sets, (s) => (s.weight_kg || 0) * (s.reps || 0))),
      });
    }
  }
  return [...by.values()].map((x) => {
    const h = x.history, last = h.at(-1), first = h[0];
    const metric = (p) => (x.kind === "weight" ? p.e1rm_kg : p.max_reps) || 0;
    const best = h.reduce((b, p) => (metric(p) > metric(b) ? p : b), h[0]);
    return { ...x, sessions: h.length, last_date: last.date, first_date: first.date,
      last: last.best_set, best: best.best_set, best_date: best.date,
      best_e1rm_kg: x.kind === "weight" ? best.e1rm_kg : null,
      change: h.length > 1 ? round(metric(last) - metric(first)) : null };
  }).sort((a, b) => b.sessions - a.sessions || b.last_date.localeCompare(a.last_date));
}

/** For the MCP tool: the same overview without every set and every point (the app gets those through the CLI). */
export async function compact(args) {
  const o = await overview(args);
  return { ...o,
    strength: { ...o.strength, exercises: o.strength.exercises.slice(0, 25).map(({ history, ...e }) => ({ ...e, recent: history.slice(-5).map(({ workout, ...h }) => h) })) },
    activities: o.activities.slice(0, 30).map(({ exercises, ...a }) => ({ ...a, ...(exercises ? { exercises: exercises.map((e) => e.name) } : {}) })) };
}

export async function overview({ days = 30 } = {}) {
  days = Math.max(7, Math.min(365, Math.round(days)));
  const to = new Date(), from = new Date(); from.setDate(to.getDate() - days + 1);
  const start = ymd(from), sources = {};

  const [raw, tpl, hb, sa, st, nutrition] = await Promise.all([
    settle("hevy", () => hevy.rawWorkouts({ days: 365 }), sources),   // a year always: exercise progress needs history
    hevy.templatesById().catch(() => ({})),
    settle("hevy_body", () => hevy.body({ limit: 60 }), sources),
    settle("strava", () => strava.activities({ days, limit: 1000 }), sources),
    settle("strava_stats", () => strava.stats(), sources),
    settle("myfitnesspal", async () => {
      const metrics = ["calories_in", "protein", "carbs", "fat", "weight"];
      const [today, ...trends] = await Promise.all([mfp("fitness_get_day", {}), ...metrics.map((metric) => mfp("fitness_get_trends", { metric, start }))]);
      return { today, trends: Object.fromEntries(metrics.map((m, i) => [m, trends[i]?.points || []])) };
    }, sources),
  ]);

  const hevyAll = raw || [];
  const hevyIn = hevyAll.filter((w) => local(w.start_time).slice(0, 10) >= start);
  const acts = sa || [];
  // A Hevy workout is usually also on Strava as "Weight Training" (Hevy syncs it): count it once, keep Hevy's (it has the sets).
  const hevyStarts = hevyIn.map((w) => Date.parse(w.start_time));
  const dupOfHevy = (a) => sportOf(a.type) === "strength" && hevyStarts.some((t) => Math.abs(Date.parse(a.date.replace(" ", "T")) - t) < 45 * 60000);

  const activities = [
    ...hevyIn.map((w) => {
      const sets = (w.exercises || []).flatMap((e) => (e.sets || []).filter((s) => s.type !== "warmup"));
      return { source: "hevy", id: String(w.id), date: local(w.start_time), title: w.title, type: "WeightTraining", sport: "strength",
        minutes: Math.round((Date.parse(w.end_time) - Date.parse(w.start_time)) / 60000), km: 0,
        volume_kg: Math.round(sum(sets, (s) => (s.weight_kg || 0) * (s.reps || 0))), sets: sets.length,
        exercises: (w.exercises || []).map((e) => ({ name: e.title, sets: (e.sets || []).map((s) => ({ type: s.type, kg: s.weight_kg ?? null, reps: s.reps ?? null,
          seconds: s.duration_seconds ?? null, meters: s.distance_meters ?? null })) })) };
    }),
    ...acts.filter((a) => !dupOfHevy(a)).map((a) => ({ source: "strava", id: String(a.id), date: a.date, title: a.name, type: a.type, sport: sportOf(a.type),
      minutes: minutes(a.moving), km: a.km, pace: a.pace ?? null, avg_hr: round(a.avg_hr, 0), max_hr: a.max_hr ?? null, elevation_m: a.elevation_m ?? 0,
      kcal: a.kcal ?? null })),
  ].sort((a, b) => b.date.localeCompare(a.date));

  // weeks of the period, oldest first, every week present even when empty (so charts have a steady axis)
  const weekKeys = [];
  for (let d = new Date(`${weekOf(start)}T12:00:00`); d <= to; d.setDate(d.getDate() + 7)) weekKeys.push(ymd(d));
  const emptyWeek = (week) => ({ week, sessions: 0, minutes: 0, km: 0, volume_kg: 0, by_sport: Object.fromEntries(SPORTS.map((s) => [s, 0])) });
  const weeks = new Map(weekKeys.map((k) => [k, emptyWeek(k)]));
  for (const a of activities) {
    const w = weeks.get(weekOf(a.date)); if (!w) continue;
    w.sessions++; w.minutes += a.minutes || 0; w.km = round(w.km + (a.km || 0)); w.volume_kg += a.volume_kg || 0; w.by_sport[a.sport]++;
  }

  const sports = SPORTS.map((key) => {
    const list = activities.filter((a) => a.sport === key);
    if (!list.length) return null;
    const wk = new Map(weekKeys.map((k) => [k, { week: k, sessions: 0, minutes: 0, km: 0, elevation_m: 0, volume_kg: 0 }]));
    for (const a of list) { const w = wk.get(weekOf(a.date)); if (w) { w.sessions++; w.minutes += a.minutes || 0; w.km = round(w.km + (a.km || 0)); w.elevation_m += a.elevation_m || 0; w.volume_kg += a.volume_kg || 0; } }
    const withKm = list.filter((a) => a.km > 0), hr = list.filter((a) => a.avg_hr);
    const longest = withKm.reduce((b, a) => (!b || a.km > b.km ? a : b), null);
    const km = round(sum(list, (a) => a.km)), mins = sum(list, (a) => a.minutes);
    return { key, sessions: list.length, minutes: mins, km, elevation_m: sum(list, (a) => a.elevation_m), avg_hr: round(avg(hr.map((a) => a.avg_hr)), 0),
      avg_km: withKm.length ? round(km / withKm.length) : null,
      avg_speed_kmh: withKm.length && sum(withKm, (a) => a.minutes) ? round(km / (sum(withKm, (a) => a.minutes) / 60)) : null,
      longest: longest ? { id: longest.id, title: longest.title, date: longest.date, km: longest.km } : null,
      volume_kg: sum(list, (a) => a.volume_kg), weekly: [...wk.values()] };
  }).filter(Boolean);

  const t = nutrition?.trends || {};
  const byDay = new Map();
  for (const [key, field] of [["calories_in", "kcal"], ["protein", "protein"], ["carbs", "carbs"], ["fat", "fat"]])
    for (const p of t[key] || []) (byDay.get(p.day) || byDay.set(p.day, { day: p.day }).get(p.day))[field] = round(p.value, 0);
  const daily = [...byDay.values()].filter((d) => d.kcal > 0).sort((a, b) => a.day.localeCompare(b.day));
  const kcalGoal = nutrition?.today?.nutrition?.goal_calories ?? null;

  const weight = [
    ...(hb || []).filter((b) => b.weight_kg && b.date >= start).map((b) => ({ day: b.date, kg: round(b.weight_kg), source: "hevy" })),
    ...(t.weight || []).filter((p) => p.value).map((p) => ({ day: p.day, kg: round(p.value), source: "myfitnesspal" })),
  ].sort((a, b) => a.day.localeCompare(b.day));
  const lastWeight = (hb || []).find((b) => b.weight_kg) || null;   // newest, even if older than the period
  const firstInPeriod = weight[0];

  const strengthList = activities.filter((a) => a.sport === "strength");
  const totals = {
    sessions: activities.length,
    strength_sessions: strengthList.length,
    hours: round(sum(activities, (a) => a.minutes) / 60),
    km: round(sum(activities, (a) => a.km)),
    volume_kg: sum(strengthList, (a) => a.volume_kg),
    avg_kcal: round(avg(daily.map((d) => d.kcal)), 0),
    avg_protein: round(avg(daily.filter((d) => d.protein != null).map((d) => d.protein)), 0),
    kcal_goal: kcalGoal,
    logged_days: daily.length,
    weight_kg: lastWeight ? round(lastWeight.weight_kg) : null,
    weight_date: lastWeight?.date ?? null,
    weight_change_kg: lastWeight && firstInPeriod && firstInPeriod.day !== lastWeight.date ? round(lastWeight.weight_kg - firstInPeriod.kg) : null,
  };

  return {
    period: { from: start, to: ymd(to), days },
    generated_at: new Date().toISOString(),
    sources,
    totals,
    weekly: [...weeks.values()],
    sports,
    strength: {
      history_from: hevyAll.length ? local(hevyAll.at(-1).start_time).slice(0, 10) : null,
      last_hevy_workout: hevyAll[0] ? local(hevyAll[0].start_time).slice(0, 10) : null,
      exercises: exerciseProgress(hevyAll, tpl),
    },
    nutrition: { goal_kcal: kcalGoal, daily, today: nutrition?.today?.nutrition ?? null },
    weight,
    activities,
    strava_totals: st,
  };
}
