// Home (com.lockedin.home, ~/Developer/Home): the household's chores and shared shopping list in Supabase.
// Brain signs in with the Home app's own session (session.json, written when the user signs in to Home on this Mac),
// so it sees exactly the user's household; row-level security keeps it to that. Changes land in Supabase, the app
// picks them up on its next sync (30 s), and so does every other member's Home.
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const DIR = path.join(os.homedir(), "Library/Application Support/Home");
const SESSION = path.join(DIR, "session.json");
// The publishable key ships in the app by design (RLS limits every query to the member's household).
const URL_ = "https://YOUR-PROJECT-REF.supabase.co";
const KEY = readKey();

function readKey() {
  // Same value as Home/Sources/HomeCore/Config.swift; read from there so it stays in one place.
  try {
    const src = fs.readFileSync(path.join(os.homedir(), "Developer/Home/Sources/HomeCore/Config.swift"), "utf8");
    return src.match(/supabaseKey = "([^"]+)"/)?.[1] || "";
  } catch { return ""; }
}

export const signedIn = () => fs.existsSync(SESSION);

/** Swift's .iso8601 date coding has no fractional seconds. */
const isoNoMs = (ms) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");

async function token() {
  let s;
  try { s = JSON.parse(fs.readFileSync(SESSION, "utf8")); } catch { throw new Error("Home nie je na tomto Macu prihlásený (otvor Home a prihlás sa)."); }
  if (new Date(s.expires).getTime() - Date.now() > 60_000) return s.accessToken;
  const r = await fetch(`${URL_}/auth/v1/token?grant_type=refresh_token`, {
    method: "POST", headers: { apikey: KEY, "Content-Type": "application/json" }, body: JSON.stringify({ refresh_token: s.refreshToken }),
  });
  const d = await r.json().catch(() => ({}));
  if (!r.ok || !d.access_token) throw new Error("Prihlásenie do Home vypršalo, prihlás sa v appke znova.");
  s = { ...s, accessToken: d.access_token, refreshToken: d.refresh_token, expires: isoNoMs(Date.now() + (d.expires_in || 3600) * 1000) };
  fs.writeFileSync(SESSION, JSON.stringify(s), { mode: 0o600 });
  return s.accessToken;
}

async function api(method, p, body, prefer) {
  const r = await fetch(`${URL_}/rest/v1/${p}`, {
    method,
    headers: { apikey: KEY, Authorization: `Bearer ${await token()}`, "Content-Type": "application/json", ...(prefer ? { Prefer: prefer } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`Supabase ${r.status}: ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
}

let hhCache;
async function household() {
  if (hhCache && Date.now() - hhCache.at < 60_000) return hhCache.h;
  const h = await api("POST", "rpc/my_household", {});
  if (!h) throw new Error("Účet v Home ešte nemá domácnosť (vytvor ju alebo sa pridaj kódom v appke).");
  hhCache = { at: Date.now(), h };
  return h;
}

const newId = () => Array.from({ length: 12 }, () => "abcdefghijklmnopqrstuvwxyz0123456789"[Math.floor(Math.random() * 36)]).join("");
const fold = (s) => s.normalize("NFD").replace(/\p{M}/gu, "").toLowerCase().trim();

// ─── Shopping ────────────────────────────────────────────────────────────

export async function shopping() {
  const h = await household();
  const rows = await api("GET", `shopping_items?household_id=eq.${h.id}&deleted=eq.false&order=updated_at.asc`);
  return { list: `Home › Nákup (${h.name}, spoločný s ${h.members.map((m) => m.name).join(", ")})`,
           on_list: rows.filter((r) => !r.done).map((r) => ({ id: r.id, title: r.name })),
           bought: rows.filter((r) => r.done).map((r) => r.name) };
}

export async function shoppingAdd({ items }) {
  const h = await household();
  const rows = await api("GET", `shopping_items?household_id=eq.${h.id}&deleted=eq.false&done=eq.false`);
  const have = new Set(rows.map((r) => fold(r.name)));
  const added = [], skipped = [], insert = [];
  for (const it of items) {
    const name = it.trim();
    if (!name || have.has(fold(name))) { skipped.push(name); continue; }
    insert.push({ household_id: h.id, id: newId(), name, done: false, deleted: false });
    have.add(fold(name)); added.push(name);
  }
  if (insert.length) await api("POST", "shopping_items?on_conflict=household_id,id", insert, "resolution=merge-duplicates,return=minimal");
  return { list: "Home › Nákup", added, already_there: skipped };
}

/** Tick items off as bought, by id (from shopping_list) or by name. */
export async function shoppingDone({ items }) {
  const h = await household();
  const rows = await api("GET", `shopping_items?household_id=eq.${h.id}&deleted=eq.false&done=eq.false`);
  const hit = [], missing = [];
  for (const it of items) {
    const r = rows.find((x) => x.id === it) || rows.find((x) => fold(x.name) === fold(it)) || rows.find((x) => fold(x.name).includes(fold(it)));
    if (r && !hit.includes(r)) hit.push(r); else missing.push(it);
  }
  if (hit.length) await api("POST", "shopping_items?on_conflict=household_id,id",
    hit.map((r) => ({ household_id: h.id, id: r.id, name: r.name, done: true, deleted: false })), "resolution=merge-duplicates,return=minimal");
  return { bought: hit.map((r) => r.name), not_found: missing };
}

// ─── Chores: the same schedule as HomeCore (Model.swift / Agenda.swift) ────

const WEEKDAYS = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"];
const MONTHS = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"];
const PARTS = { Morning: "ráno", Afternoon: "poobede", Evening: "večer", Anytime: "kedykoľvek" };
const D = (s) => new Date(s + "T00:00:00Z");
const fmt = (d) => d.toISOString().slice(0, 10);
const addDays = (s, n) => fmt(new Date(D(s).getTime() + n * 864e5));
const weekday = (s) => ((D(s).getUTCDay() + 6) % 7) + 1;
const weekStart = (s) => addDays(s, -(weekday(s) - 1));
const monthStart = (s) => s.slice(0, 8) + "01";
const monthEnd = (s) => { const d = D(monthStart(s)); d.setUTCMonth(d.getUTCMonth() + 1); return addDays(fmt(d), -1); };
const weekIndex = (s) => Math.round((D(weekStart(s)) - D("2024-01-01")) / (7 * 864e5));
const monthIndex = (s) => Number(s.slice(0, 4)) * 12 + Number(s.slice(5, 7)) - 1;
const isoWeek = (s) => { const d = D(s); d.setUTCDate(d.getUTCDate() + 4 - weekday(s)); const y = new Date(Date.UTC(d.getUTCFullYear(), 0, 1)); return Math.ceil(((d - y) / 864e5 + 1) / 7); };
const javaHash = (s) => { let h = 0; for (let i = 0; i < s.length; i++) h = (Math.imul(h, 31) + s.charCodeAt(i)) | 0; return h; };
export const localToday = () => new Date().toLocaleDateString("sv-SE");

const flexible = (t) => t.repeat.type === "flexible" || t.repeat.type === "window";
const period = (t) => t.repeat.type === "flexible" ? t.repeat.period : t.repeat.type === "window" ? ((D(t.repeat.end) - D(t.repeat.start)) / 864e5 <= 7 ? "Week" : "Month") : null;
const periodStart = (t, d) => t.repeat.type === "window" ? t.repeat.start : t.repeat.type === "flexible" ? (t.repeat.period === "Week" ? weekStart(d) : monthStart(d)) : d;
const periodEnd = (t, d) => t.repeat.type === "window" ? t.repeat.end : t.repeat.type === "flexible" ? (t.repeat.period === "Week" ? addDays(weekStart(d), 6) : monthEnd(d)) : d;
const doneDay = (t, d) => flexible(t) ? periodStart(t, d) : d;
function occurs(t, d) {
  const r = t.repeat;
  return r.type === "once" ? r.date === d : r.type === "daily" ? true : r.type === "weekly" ? (r.days || []).includes(WEEKDAYS[weekday(d) - 1]) : false;
}
function dueInPeriod(t, d) {
  const r = t.repeat;
  if (r.type === "window") return d >= r.start && d <= r.end;
  if (r.type !== "flexible") return false;
  const n = Math.max(r.every || 1, 1), idx = r.period === "Week" ? weekIndex(d) : monthIndex(d);
  return (((idx - (r.anchor || 0)) % n) + n) % n === 0 && (!(r.months || []).length || r.months.includes(MONTHS[Number(d.slice(5, 7)) - 1]));
}
function whoOn(t, d, members) {
  if (t.who !== "Take turns" || !members.length) return t.who;
  const idx = period(t) === "Month" ? monthIndex(periodStart(t, d)) : isoWeek(d);
  return members[(idx + Math.abs(javaHash(t.id))) % members.length];
}
const whoTitle = (w) => w === "Anyone" ? "ktokoľvek" : w === "Take turns" ? "striedajú sa" : w;

async function load() {
  const h = await household();
  const [tasks, done] = await Promise.all([
    api("GET", `tasks?household_id=eq.${h.id}&deleted=eq.false`),
    api("GET", `task_completions?household_id=eq.${h.id}&done=eq.true&period=gte.${addDays(localToday(), -62)}`),
  ]);
  const doneMap = new Map(done.map((c) => [`${c.task_id}@${c.period}`, c.done_by]));
  return { h, tasks, doneMap, members: h.members.map((m) => m.name) };
}

/** The day's chores (and this week's/month's, and missed ones) with who and whether they're done. */
export async function tasks({ day } = {}) {
  const { h, tasks, doneMap, members } = await load();
  const d = day || localToday();
  const item = (t, on) => {
    const key = `${t.id}@${doneDay(t, on)}`;
    return { id: t.id, title: t.title, who: whoTitle(whoOn(t, on, members)), part: PARTS[t.part] || t.part,
             done: doneMap.has(key), ...(doneMap.get(key) ? { done_by: doneMap.get(key) } : {}), ...(on !== d ? { for_day: on } : {}) };
  };
  const overdue = tasks.flatMap((t) => {
    const r = t.repeat; let missed = null;
    if (r.type === "once" && r.date < d && r.date >= addDays(d, -14)) missed = r.date;
    if (r.type === "window" && r.end < d && r.end >= addDays(d, -14)) missed = r.end;
    if (r.type === "flexible") { const prev = addDays(periodStart(t, d), -1); if (dueInPeriod(t, prev) && periodEnd(t, prev) >= addDays(d, -14)) missed = prev; }
    return missed && !doneMap.has(`${t.id}@${doneDay(t, missed)}`) ? [item(t, missed)] : [];
  });
  return {
    household: h.name, day: d, members,
    day_tasks: tasks.filter((t) => !flexible(t) && occurs(t, d)).map((t) => item(t, d)),
    this_week: tasks.filter((t) => flexible(t) && period(t) === "Week" && dueInPeriod(t, d)).map((t) => item(t, d)),
    this_month: tasks.filter((t) => flexible(t) && period(t) === "Month" && dueInPeriod(t, d)).map((t) => item(t, d)),
    overdue,
    all_chores: tasks.length,
  };
}

/** Add a chore or one-off task. */
export async function taskAdd({ title, who = "Anyone", part = "Anytime", repeat = "once", date, days, every = 1, months, end }) {
  const { h, members } = await load();
  const today = localToday();
  const W = { mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6, sun: 7, po: 1, ut: 2, st: 3, št: 4, pi: 5, so: 6, ne: 7 };
  const rule = repeat === "daily" ? { type: "daily" }
    : repeat === "weekly" ? { type: "weekly", days: (days || []).map((x) => WEEKDAYS[(W[String(x).toLowerCase().slice(0, 3)] || W[String(x).toLowerCase().slice(0, 2)] || Number(x)) - 1]).filter(Boolean) }
    : repeat === "every_n_weeks" ? { type: "flexible", period: "Week", every, months: [], anchor: weekIndex(date || today) }
    : repeat === "every_n_months" ? { type: "flexible", period: "Month", every: (months || []).length ? 1 : every, months: (months || []).map((m) => MONTHS[Number(m) - 1]).filter(Boolean), anchor: monthIndex(date || today) }
    : repeat === "window" ? { type: "window", start: date || today, end: end || addDays(date || today, 7) }
    : { type: "once", date: date || today };
  if (rule.type === "weekly" && !rule.days.length) throw new Error("Pre repeat=weekly treba days, napr. ['mon','thu'].");
  const whoV = ["anyone", "ktokoľvek", "ktokolvek"].includes(fold(who)) ? "Anyone"
    : ["take turns", "striedame sa", "striedat", "striedať"].includes(fold(who)) ? "Take turns"
    : members.find((m) => fold(m) === fold(who) || fold(m).startsWith(fold(who))) || who;
  const partV = { morning: "Morning", rano: "Morning", afternoon: "Afternoon", poobede: "Afternoon", evening: "Evening", vecer: "Evening" }[fold(part)] || "Anytime";
  const row = { household_id: h.id, id: newId(), title: title.trim(), who: whoV, part: partV, repeat: rule, deleted: false };
  await api("POST", "tasks?on_conflict=household_id,id", [row], "resolution=merge-duplicates,return=minimal");
  return { added: { id: row.id, title: row.title, who: whoTitle(whoV), part: PARTS[partV], repeat: rule } };
}

/** Tick a chore off (or back on with done=false) for a day (default today; week/month chores count for their period). */
export async function taskDone({ task, day, done = true }) {
  const { h, tasks, members } = await load();
  const t = tasks.find((x) => x.id === task) || tasks.find((x) => fold(x.title) === fold(task)) || tasks.find((x) => fold(x.title).includes(fold(task)));
  if (!t) throw new Error(`Úlohu „${task}“ v Home nepoznám.`);
  const d = day || localToday();
  const me = members[0] && JSON.parse(fs.readFileSync(SESSION, "utf8")).userId;
  const by = h.members.find((m) => m.user_id === me)?.name || null;
  await api("POST", "task_completions?on_conflict=household_id,task_id,period",
    [{ household_id: h.id, task_id: t.id, period: doneDay(t, d), done, done_by: done ? by : null }], "resolution=merge-duplicates,return=minimal");
  return { task: t.title, for: doneDay(t, d), done, by };
}
