// Strava through its API. The user creates their own API application (strava.com/settings/api, callback domain localhost)
// and `brain strava-setup` asks for its Client ID and Secret in Terminal; `brain strava-login` then signs in once in the
// browser. Tokens (6 h) refresh by themselves. Reads run straight away; edits and manual activities are proposals.
import { execFile } from "node:child_process";
import http from "node:http";
import { promisify } from "node:util";
import { p } from "./paths.js";
import { readJSON, writeJSON } from "./store.js";

const API = "https://www.strava.com/api/v3";
const FILE = p("strava.json");   // { client_id, client_secret, access_token, refresh_token, expires_at, athlete }
const PORT = 33419, REDIRECT = `http://localhost:${PORT}/callback`;
const SCOPES = "read,profile:read_all,activity:read_all,activity:write";

const cfg = () => readJSON(FILE, {});
export const connected = () => !!cfg().refresh_token;

async function token() {
  const c = cfg();
  if (!c.client_id) throw new Error("Strava isn't set up: run `node ~/Developer/brain/src/cli.js strava-setup` (needs your Strava API application).");
  if (!c.refresh_token) throw new Error("Strava isn't signed in: run `node ~/Developer/brain/src/cli.js strava-login`.");
  if (c.access_token && c.expires_at * 1000 > Date.now() + 60000) return c.access_token;
  const t = await exchange({ grant_type: "refresh_token", refresh_token: c.refresh_token });
  return t.access_token;
}

async function exchange(params) {
  const c = cfg();
  const r = await fetch("https://www.strava.com/oauth/token", { method: "POST", headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ client_id: c.client_id, client_secret: c.client_secret, ...params }) });
  const t = await r.json();
  if (!r.ok || !t.access_token) throw new Error(`Strava sign-in failed: ${JSON.stringify(t).slice(0, 200)}`);
  writeJSON(FILE, { ...cfg(), access_token: t.access_token, refresh_token: t.refresh_token, expires_at: t.expires_at, ...(t.athlete ? { athlete: { id: t.athlete.id, name: `${t.athlete.firstname} ${t.athlete.lastname}` } } : {}) });
  return t;
}

async function api(path, { method = "GET", query, body } = {}) {
  const url = new URL(API + path);
  for (const [k, v] of Object.entries(query || {})) if (v !== undefined && v !== null) url.searchParams.set(k, String(v));
  const r = await fetch(url, { method, headers: { authorization: `Bearer ${await token()}`, ...(body ? { "content-type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(20000) });
  if (r.status === 429) throw new Error("Strava rate limit reached; try again in a few minutes.");
  if (!r.ok) throw new Error(`Strava ${method} ${path}: ${r.status} ${(await r.text()).slice(0, 200)}`);
  return r.json();
}

/** Save the API application's Client ID and Secret (typed by the user in Terminal). */
export function saveApp(client_id, client_secret) {
  if (!/^\d+$/.test(String(client_id)) || !/^[0-9a-f]{40}$/i.test(String(client_secret))) throw new Error("Client ID is a number and Client Secret 40 hex characters (strava.com/settings/api)");
  writeJSON(FILE, { ...cfg(), client_id: String(client_id), client_secret: String(client_secret) });
  return { saved: true, next: "node ~/Developer/brain/src/cli.js strava-login" };
}

/** One-time sign-in in the browser. */
export async function login() {
  const c = cfg();
  if (!c.client_id) throw new Error("run strava-setup first");
  const server = http.createServer();
  await new Promise((ok, fail) => server.once("error", fail).listen(PORT, "127.0.0.1", ok));
  try {
    const code = new Promise((ok, fail) => {
      server.on("request", (req, res) => {
        const u = new URL(req.url, REDIRECT);
        if (u.pathname !== "/callback") { res.writeHead(404).end(); return; }
        res.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end("<h2>Brain je pripojený k Strave. Toto okno môžeš zavrieť.</h2>");
        u.searchParams.get("code") ? ok(u.searchParams.get("code")) : fail(new Error(u.searchParams.get("error") || "not approved"));
      });
      setTimeout(() => fail(new Error("no sign-in within 5 minutes")), 300000).unref();
    });
    const auth = new URL("https://www.strava.com/oauth/authorize");
    for (const [k, v] of Object.entries({ client_id: c.client_id, redirect_uri: REDIRECT, response_type: "code", approval_prompt: "auto", scope: SCOPES })) auth.searchParams.set(k, v);
    await promisify(execFile)("open", [auth.toString()]);
    const t = await exchange({ grant_type: "authorization_code", code: await code });
    return { connected: true, athlete: t.athlete ? `${t.athlete.firstname} ${t.athlete.lastname}` : undefined };
  } finally {
    server.close();
  }
}

const km = (m) => Math.round(m / 10) / 100;
const hm = (s) => `${Math.floor(s / 3600)}:${String(Math.floor(s % 3600 / 60)).padStart(2, "0")}`;
const pace = (a) => /Run|Walk|Hike/.test(a.sport_type || a.type) && a.distance ? `${Math.floor(a.moving_time / (a.distance / 1000) / 60)}:${String(Math.round(a.moving_time / (a.distance / 1000) % 60)).padStart(2, "0")} /km`
  : a.average_speed ? `${Math.round(a.average_speed * 36) / 10} km/h` : undefined;

function row(a) {
  return { id: a.id, name: a.name, type: a.sport_type || a.type, date: String(a.start_date_local).slice(0, 16).replace("T", " "), km: km(a.distance || 0),
    moving: hm(a.moving_time || 0), pace: pace(a), elevation_m: Math.round(a.total_elevation_gain || 0), avg_hr: a.average_heartrate, max_hr: a.max_heartrate,
    watts: a.average_watts, kcal: a.calories, suffer: a.suffer_score };
}

/** Recent activities, newest first; days / type filter (Run, Ride, Swim, WeightTraining, …). */
export async function activities({ days = 30, type, limit = 30 } = {}) {
  const after = Math.floor((Date.now() - days * 86400000) / 1000);
  const out = [];
  for (let page = 1; page <= 10 && out.length < limit; page++) {
    const r = await api("/athlete/activities", { query: { after, page, per_page: 50 } });
    out.push(...r.filter((a) => !type || new RegExp(type, "i").test(a.sport_type || a.type)).map(row));
    if (r.length < 50) break;
  }
  return out.sort((a, b) => b.date.localeCompare(a.date)).slice(0, limit);
}

/** One activity in detail: description, splits per km, laps, best efforts, gear. */
export async function activity({ id }) {
  const a = await api(`/activities/${id}`);
  return { ...row(a), description: a.description, gear: a.gear?.name, device: a.device_name,
    splits_km: (a.splits_metric || []).map((s) => ({ km: s.split, time: hm(s.moving_time), pace: pace({ ...a, moving_time: s.moving_time, distance: s.distance }), hr: s.average_heartrate })),
    laps: (a.laps || []).map((l) => ({ name: l.name, km: km(l.distance), time: hm(l.moving_time), hr: l.average_heartrate })),
    best_efforts: (a.best_efforts || []).map((b) => ({ name: b.name, time: hm(b.moving_time), pr: b.pr_rank || undefined })) };
}

/** Totals: recent 4 weeks, this year and all time, for runs, rides and swims. */
export async function stats() {
  const id = cfg().athlete?.id || (await api("/athlete")).id;
  const s = await api(`/athletes/${id}/stats`);
  const t = (x) => x && { count: x.count, km: km(x.distance), hours: Math.round(x.moving_time / 360) / 10, elevation_m: Math.round(x.elevation_gain || 0) };
  return { run: { last_4_weeks: t(s.recent_run_totals), year: t(s.ytd_run_totals), all: t(s.all_run_totals) },
           ride: { last_4_weeks: t(s.recent_ride_totals), year: t(s.ytd_ride_totals), all: t(s.all_ride_totals) },
           swim: { last_4_weeks: t(s.recent_swim_totals), year: t(s.ytd_swim_totals) } };
}

export function planUpdate({ id, name, description, sport_type, hide_from_home, commute, gear_id }) {
  const body = Object.fromEntries(Object.entries({ name, description, sport_type, hide_from_home, commute, gear_id }).filter(([, v]) => v !== undefined));
  if (!Object.keys(body).length) throw new Error("nothing to change");
  return { action: { type: "strava", op: "update", id, body, what: String(id) },
           summary: `Strava: upraviť aktivitu ${id}: ${Object.entries(body).map(([k, v]) => `${k} → ${v}`).join(", ")}` };
}

export function planCreate({ name, sport_type, start, minutes, km: dist, description }) {
  const body = { name, sport_type, start_date_local: start, elapsed_time: Math.round(minutes * 60), ...(dist ? { distance: dist * 1000 } : {}), ...(description ? { description } : {}) };
  return { action: { type: "strava", op: "create", body, what: name },
           summary: `Strava: nová manuálna aktivita „${name}“ (${sport_type}) ${start.replace("T", " ")}, ${minutes} min${dist ? `, ${dist} km` : ""}` };
}

export async function exec(a) {
  if (a.op === "update") { const r = await api(`/activities/${a.id}`, { method: "PUT", body: a.body }); return { updated: r.id, name: r.name }; }
  if (a.op === "create") { const r = await api("/activities", { method: "POST", body: a.body }); return { created: r.id, name: r.name }; }
  throw new Error(`unknown Strava op ${a.op}`);
}
