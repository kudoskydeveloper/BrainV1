// Apple Health through the iPhone app Health Auto Export: an automation exports Health Metrics as JSON, summarized by day,
// to iCloud Drive; the files land in the app's iCloud folder on this Mac and Brain reads them (read only, nothing leaves).
// The older AutoSync folder (.hae, raw samples) is left alone.
import fs from "node:fs";
import path from "node:path";
import { HOME } from "./paths.js";
import { config } from "./store.js";
import { status } from "./ui.js";

const ROOT_DIR = path.join(HOME, "Library/Mobile Documents/iCloud~com~ifunography~HealthExport/Documents");
const dir = () => config().health?.folder ? path.join(ROOT_DIR, config().health.folder) : ROOT_DIR;

/** Every exported JSON file (newest last, so newer data wins). */
function files(root) {
  const out = [];
  (function walk(d) {
    let list = [];
    try { list = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
    for (const e of list) {
      const f = path.join(d, e.name);
      if (e.isDirectory() && e.name !== "AutoSync") walk(f);
      else if (e.isFile() && e.name.endsWith(".json")) out.push({ f, t: fs.statSync(f).mtimeMs });
    }
  })(root);
  return out.sort((a, b) => a.t - b.t).map((x) => x.f);
}

const round = (v) => typeof v === "number" ? Math.round(v * 100) / 100 : v;
const NAMES = { step_count: "steps", active_energy: "active_kcal", basal_energy_burned: "resting_kcal", resting_heart_rate: "resting_hr",
  heart_rate_variability: "hrv_ms", walking_running_distance: "km", flights_climbed: "floors", apple_exercise_time: "exercise_min",
  apple_stand_hour: "stand_hours", weight_body_mass: "weight_kg", body_fat_percentage: "body_fat_pct", vo2_max: "vo2max",
  respiratory_rate: "breaths_min", blood_oxygen_saturation: "spo2_pct", walking_heart_rate_average: "walking_hr", sleep_analysis: "sleep",
  heart_rate: "hr", dietary_water: "water_ml", mindful_minutes: "mindful_min" };

/** day → metric → value, merged over all files (a later export of the same day replaces the earlier one). */
export function load(root = dir()) {
  const days = {}, units = {};
  let workouts = [];
  for (const f of files(root)) {
    let j;
    try { j = JSON.parse(fs.readFileSync(f, "utf8")); } catch { continue; }
    const data = j.data || j;
    for (const m of data.metrics || []) {
      const key = NAMES[m.name] || m.name;
      units[key] = m.units;
      const perDay = {};
      for (const pt of m.data || []) {
        const day = String(pt.date || "").slice(0, 10);
        if (!day) continue;
        const { date, source, ...rest } = pt;
        let v = "qty" in rest ? rest.qty : rest;
        if (key === "sleep" && typeof v === "object") v = { total_h: round(v.totalSleep ?? v.asleep), deep_h: round(v.deep), rem_h: round(v.rem), core_h: round(v.core),
          awake_h: round(v.awake), in_bed_h: round(v.inBed), from: v.sleepStart?.slice(11, 16), to: v.sleepEnd?.slice(11, 16) };
        else if (typeof v === "object") v = Object.fromEntries(Object.entries(v).map(([k, x]) => [k.toLowerCase(), round(x)]));
        else v = round(v);
        // several points for one day (several sources): sum counts, keep the last of everything else
        perDay[day] = typeof v === "number" && typeof perDay[day] === "number" && /steps|kcal|km|floors|min|hours|ml/.test(key) ? round(perDay[day] + v) : v;
      }
      for (const [day, v] of Object.entries(perDay)) (days[day] ||= {})[key] = v;
    }
    if (data.workouts?.length) workouts = workouts.concat(data.workouts.map((w) => ({ name: w.name, start: String(w.start).slice(0, 16),
      minutes: Math.round((w.duration || 0) / 60), kcal: Math.round(w.activeEnergyBurned?.qty || w.activeEnergy?.qty || 0) || undefined })));
  }
  return { days, units, workouts };
}

export function health({ from, to, metrics } = {}) {
  status("Čítam dáta zo Zdravia (Health Auto Export)");
  const { days, units, workouts } = load();
  const all = Object.keys(days).sort();
  if (!all.length) return { setup_needed: true, folder: dir(),
    how: "V iPhone appke Health Auto Export: Automations → nová → iCloud Drive, Data Type Health Metrics, Export Format JSON, Summarize Data zapnuté (Day), Date Range Last 7 Days, Sync Cadence každú hodinu. Súbory prídu sem cez iCloud." };
  const today = new Date().toLocaleDateString("sv-SE");
  to = to || today;
  from = from || new Date(Date.parse(to) - 6 * 86400e3).toISOString().slice(0, 10);
  const want = metrics?.length ? new Set(metrics.map((m) => NAMES[m] || m)) : null;
  const rows = all.filter((d) => d >= from && d <= to).map((d) => ({ date: d,
    ...Object.fromEntries(Object.entries(days[d]).filter(([k]) => !want || want.has(k))) }));
  return { from, to, days: rows, units, last_data: all.at(-1),
    workouts: workouts.filter((w) => w.start.slice(0, 10) >= from && w.start.slice(0, 10) <= to),
    note: all.at(-1) < today ? `Najnovšie dáta sú z ${all.at(-1)}; iPhone posiela keď je odomknutý.` : undefined };
}
