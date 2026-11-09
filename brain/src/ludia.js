// Ľudia: a personal CRM over what Brain already reads. One row per person you actually talk to, with the last contact on
// every channel (WhatsApp, e-mail in Courier, Beeper: Messenger / iMessage / Telegram / Instagram / LinkedIn, recorded and
// upcoming meetings), their company, birthday and name day, plus what you add yourself: follow (with how often to be in
// touch), a note and promises. "Ozvi sa" = followed people you haven't talked to for longer than their interval.
// Your own additions live in data/ludia.json; the Ľudia app (com.lockedin.ludia, in Hangar) reads `brain ludia`.
import { execFile } from "node:child_process";
import fs from "node:fs";
import { promisify } from "node:util";
import * as beeper from "./beeper.js";
import * as calendar from "./calendar.js";
import * as catalog from "./catalog.js";
import * as celebrations from "./celebrations.js";
import { DB as COURIER_DB } from "./courier.js";
import * as meetings from "./meetings.js";
import { fold, recall } from "./notes.js";
import { p } from "./paths.js";
import { callTool, resultText } from "./pool.js";
import { appendLine, config, readJSON, writeJSON } from "./store.js";
import { status } from "./ui.js";
import * as wa from "./whatsapp.js";

const run = promisify(execFile);
const STATE = p("ludia.json");        // { people: [{ keys: [...], name, follow, every, note, business, hidden, promises: [...] }] }
const LAST = p("ludia-last.json");    // the last overview, so a detail can find a person by id
const DEFAULTS = {
  every_days: 60,                     // default "ozvi sa" interval for a followed person
  fading_days: 60,                    // a strong contact not followed and silent this long shows under "Zabúdaš"
  // what each source does: "add" = can add a person to the list, "enrich" = only adds the last contact (company, birthday)
  // to someone already there, "off" = not read. Beeper chats are one-to-one only (never groups); LinkedIn has lots of cold
  // chats, so it only enriches. WhatsApp is read from its own database, not through Beeper. The app changes these
  // (Nastavenia), stored in data/ludia.json "sources".
  sources: { whatsapp: "add", mail: "add", meetings: "add", contacts: "enrich",
             Messenger: "add", iMessage: "add", Telegram: "add", Instagram: "enrich", LinkedIn: "enrich" },
  me: [],   // brain.config.json → ludia.me (your names and addresses)
};
const BEEPER = { Messenger: "Facebook", iMessage: "iMessage", Telegram: "Telegram", Instagram: "Instagram", LinkedIn: "LinkedIn" };
export const SOURCES = ["whatsapp", "mail", "meetings", "contacts", ...Object.keys(BEEPER)];
const settings = () => {
  const c = { ...DEFAULTS, ...(config().ludia || {}) }, st = readJSON(STATE, {});
  return { ...c, every_days: st.every_days || c.every_days, fading_days: st.fading_days || c.fading_days, crm: st.crm || null,
           sources: { ...DEFAULTS.sources, ...(c.sources || {}), ...(st.sources || {}) } };
};
const mode = (s, k) => s.sources[k] || "off";

const FREEMAIL = /^(gmail|googlemail|icloud|me|mac|yahoo|outlook|hotmail|live|seznam|centrum|azet|post|zoznam|proton|protonmail|atlas|email)\./;
const ROBOT = /(no-?reply|do-?not-?reply|mailer-daemon|notification|bounce|newsletter|calendar|resource\.|invoice|billing|support@|noreply|@.*(atlassian|google|facebookmail|linkedin|slack|notion|github)\.)/i;
const today = () => new Date().toLocaleDateString("sv-SE");
const daysSince = (d) => (d ? Math.max(0, Math.floor((Date.parse(today()) - Date.parse(d.slice(0, 10))) / 86400000)) : null);
const maxDate = (...d) => d.filter(Boolean).sort().at(-1) || null;
const clean = (s) => String(s || "").replace(/[‪‬]/g, "").trim();

/** Phone digits in one form: "0902 365 993" → "421902365993", "+420 775…" → "420775…". */
export function normPhone(s) {
  let d = String(s || "").replace(/\D/g, "");
  if (d.startsWith("00")) d = d.slice(2);
  if (d.length === 10 && d.startsWith("0")) d = "421" + d.slice(1);
  return d.length >= 9 ? d : "";
}
const nameKey = (n) => { const f = fold(clean(n)).replace(/[^a-z ]/g, " ").replace(/\s+/g, " ").trim(); return f.includes(" ") ? f : ""; };
const keysOf = ({ phones = [], emails = [], names = [] }) => [
  ...phones.map(normPhone).filter(Boolean).map((x) => "tel:" + x),
  ...emails.map((e) => String(e).toLowerCase()).filter(Boolean).map((e) => "mail:" + e),
  ...names.filter((n) => n && !String(n).includes("@")).map(nameKey).filter(Boolean).map((n) => "name:" + n),
];

// ---- sources ----------------------------------------------------------------------------------------------------------

async function sql(db, query) {
  const { stdout } = await run("/usr/bin/sqlite3", ["-readonly", "-json", db, query], { maxBuffer: 1 << 28, timeout: 30000 });
  return stdout.trim() ? JSON.parse(stdout) : [];
}
const parseAddrs = (line) => [...String(line || "").matchAll(/(?:"?([^",<]*?)"?\s*<)?([\w.+-]+@[\w-]+(?:\.[\w-]+)+)>?/g)]
  .map((m) => ({ name: clean(m[1]), email: m[2].toLowerCase() }));

/** Per address: mail received from people (not newsletters) and mail you sent, with the last subject. */
async function courierPeople(isMe) {
  if (!fs.existsSync(COURIER_DB)) throw new Error("Courier nemá databázu");
  const join = "FROM messages m JOIN folders f ON f.account_id = m.account_id AND f.path = m.folder";
  const [got, sent] = await Promise.all([
    sql(COURIER_DB, `SELECT lower(m.from_addr) email, m.from_name name, m.message_id mid, m.subject, m.date ${join}
      WHERE coalesce(m.category, 'people') = 'people' AND f.role IN ('inbox', 'archive', 'all', 'other') AND m.from_addr != ''`),
    sql(COURIER_DB, `SELECT m.to_line t, m.cc_line c, m.message_id mid, m.subject, m.date ${join} WHERE f.role = 'sent'`),
  ]);
  const by = new Map();
  const at = (email, name) => {
    let x = by.get(email);
    if (!x) by.set(email, (x = { email, names: new Set(), received: new Set(), sent: new Set(), last: 0, last_subject: "" }));
    if (name && !name.includes("@")) x.names.add(name);
    return x;
  };
  const touch = (x, r) => { if (r.date > x.last) { x.last = r.date; x.last_subject = r.subject || ""; } };
  for (const r of got) { if (isMe(r.email) || ROBOT.test(r.email)) continue; const x = at(r.email, clean(r.name)); x.received.add(r.mid || r.date); touch(x, r); }
  for (const r of sent) {
    for (const a of parseAddrs(`${r.t || ""},${r.c || ""}`)) {
      if (isMe(a.email) || ROBOT.test(a.email)) continue;
      const x = at(a.email, a.name); x.sent.add(r.mid || r.date); touch(x, r);
    }
  }
  // an address that writes under three or more names is a shared or system mailbox ("Name, Company"), not one person
  return [...by.values()].filter((x) => x.names.size < 3).map((x) => ({ email: x.email, names: [...x.names].filter((n) => !isMe(n)), received: x.received.size, sent: x.sent.size,
    last: x.last ? new Date(x.last * 1000).toISOString() : null, last_subject: x.last_subject }));
}

/** One-to-one Beeper chats of the networks in settings (never groups). */
async function beeperChats(s) {
  const nets = Object.keys(BEEPER).filter((k) => mode(s, k) !== "off");
  if (!nets.length) return [];
  if (!beeper.connected()) throw new Error("Beeper nie je pripojený (brain beeper-login)");
  const all = await Promise.all(nets.map((k) => beeper.chats({ network: BEEPER[k], limit: 200 })
    .then((list) => list.map((c) => ({ ...c, net: k, adds: mode(s, k) === "add" }))).catch(() => [])));
  return all.flat().filter((c) => c.kind === "chat" && c.name);
}

/** Business a person belongs to, from e-mail domains, meetings and WhatsApp groups. */
function guessBusiness(x) {
  const d = x.emails.map((e) => e.split("@")[1] || "");
  const groups = x.groups.join(" ");
  if (d.includes("kudosky.com") || x.meetings.some((m) => m.business === "kudosky") || /kudosky/i.test(groups)) return "kudosky";
  if (d.includes("weare10t.com") || x.meetings.some((m) => m.business === "10t") || /\b10T\b/.test(groups)) return "10t";
  if (d.some((v) => v && !FREEMAIL.test(v)) || x.company) return "work";
  return "personal";
}

// ---- overview ---------------------------------------------------------------------------------------------------------

/** Everyone worth showing, newest contact first, with "ozvi sa", "zabúdaš" and celebrations. */
export async function overview({ days = 365 } = {}) {
  const s = settings();
  const meFold = s.me.map(fold);
  const isMe = (v) => { const f = fold(v); return meFold.some((m) => f.includes(m)); };
  const sources = {};
  const safe = (name, pr) => pr.then((r) => { sources[name] = { ok: true }; return r; })
    .catch((e) => { sources[name] = { ok: false, error: String(e.message || e).slice(0, 200) }; return null; });

  status("Ľudia: čítam WhatsApp, Courier, Beeper, meetingy a kontakty");
  const on = (k, pr) => (mode(s, k) === "off" ? Promise.resolve(null) : safe(k, pr()));
  const [waRows, mail, chats, meet, contacts, celeb] = await Promise.all([
    on("whatsapp", () => wa.contactsAndMembers()),
    on("mail", () => courierPeople(isMe)),
    safe("beeper", beeperChats(s)),
    on("meetings", () => meetings.overview({ days: 365, ahead: 30 })),
    on("contacts", () => celebrations.contacts()),
    on("contacts", () => yearOfCelebrations(days)),
  ]);
  const adds = (k) => mode(s, k) === "add";
  const graph = readJSON(p("people-graph.json"), { people: [] }).people;

  // union-find over records that share a phone, e-mail or full name
  const recs = [];
  const parent = [];
  const owner = new Map();
  const find = (i) => (parent[i] === i ? i : (parent[i] = find(parent[i])));
  const add = (rec, keys) => {
    const i = recs.push(rec) - 1; parent.push(i);
    for (const k of keys) { if (owner.has(k)) parent[find(i)] = find(owner.get(k)); else owner.set(k, i); }
  };
  const base = () => ({ names: [], emails: [], phones: [], groups: [], meetings: [], adds: false });

  for (const c of waRows?.contacts || []) {
    if (/@g\.us$/.test(c.jid || "")) continue;
    const names = looksNumber(c.name) ? [] : [clean(c.name)];
    const phones = [c.phone].filter(Boolean);
    add({ ...base(), names, phones, whatsapp: { chat: clean(c.name), phone: normPhone(c.phone), messages: c.messages, last: c.last }, adds: adds("whatsapp") && c.messages >= 5 },
        keysOf({ phones, names }));
  }
  for (const m of mail || []) {
    add({ ...base(), names: m.names, emails: [m.email], mail: m, adds: adds("mail") && m.sent > 0 && m.received > 0 }, keysOf({ emails: [m.email], names: m.names }));
  }
  for (const c of chats || []) {
    if (isMe(c.name)) continue;
    add({ ...base(), names: [clean(c.name)], chats: [{ id: c.id, network: c.net, last: c.last, unread: c.unread }], adds: c.adds && personLike(c.name) },
        keysOf({ names: [c.name] }));
  }
  for (const r of meet?.recordings || []) {
    for (const x of r.people || []) {
      const name = clean(x.name), email = (x.email || "").toLowerCase();
      if (isMe(`${name} ${email}`) || ROBOT.test(email)) continue;
      add({ ...base(), names: name ? [name] : [], emails: email ? [email] : [],
            meetings: [{ title: r.title, date: String(r.date || r.when || "").slice(0, 10), path: r.path, business: r.business }], adds: adds("meetings") },
          keysOf({ names: [name], emails: [email] }));
    }
  }
  for (const u of meet?.upcoming || []) {
    for (const x of u.people || []) {
      const email = (x.email || "").toLowerCase();
      if (!email || isMe(`${x.name} ${email}`) || ROBOT.test(email)) continue;
      add({ ...base(), names: x.name ? [clean(x.name)] : [], emails: [email], next: { title: u.title, start: u.start, id: u.id }, adds: adds("meetings") },
          keysOf({ names: [x.name], emails: [email] }));
    }
  }
  // a number saved on two or more contacts is a company line, not anyone's own
  const owners = new Map();
  for (const c of contacts || []) for (const ph of (c.phones || []).map(normPhone)) owners.set(ph, (owners.get(ph) || 0) + 1);
  for (const c of contacts || []) {
    const name = [c.given, c.family].filter(Boolean).join(" ");
    if (!name || isMe(name)) continue;
    const phones = (c.phones || []).filter((ph) => owners.get(normPhone(ph)) < 2);
    add({ ...base(), names: [name], emails: c.emails || [], phones, contact: { name, company: c.company, birthday: c.birthday }, adds: adds("contacts") },
        keysOf({ names: [name], emails: c.emails, phones }));
  }
  for (const g of graph) {   // WhatsApp groups only tell which business someone belongs to
    if (!g.groups?.length || !g.phones?.length) continue;
    for (const ph of g.phones) add({ ...base(), phones: [ph], groups: g.groups.filter(Boolean) }, keysOf({ phones: [ph] }));
  }

  // people you merged by hand (Zlúčiť): their keys are one person
  const state = readJSON(STATE, { people: [] });
  for (const e of state.people) if (e.links?.length) add({ ...base() }, [...e.keys, ...e.links]);

  // merge groups
  const groups = new Map();
  recs.forEach((r, i) => { const k = find(i); groups.set(k, [...(groups.get(k) || []), r]); });
  const stateOf = (keys) => state.people.find((e) => [...e.keys, ...(e.links || [])].some((k) => keys.includes(k)));

  const people = [];
  const stById = new Map();
  for (const parts of groups.values()) {
    const x = base();
    for (const r of parts) {
      x.names.push(...r.names); x.emails.push(...r.emails); x.phones.push(...r.phones.map(normPhone).filter(Boolean)); x.groups.push(...r.groups);
      x.meetings.push(...r.meetings); x.adds ||= r.adds;
      if (r.whatsapp && (!x.whatsapp || r.whatsapp.messages > x.whatsapp.messages)) x.whatsapp = r.whatsapp;
      if (r.mail) x.mail = x.mail ? { ...x.mail, sent: x.mail.sent + r.mail.sent, received: x.mail.received + r.mail.received,
        ...(r.mail.last > x.mail.last ? { last: r.mail.last, last_subject: r.mail.last_subject } : {}), emails: [...(x.mail.emails || [x.mail.email]), r.mail.email] } : r.mail;
      if (r.chats) x.chats = [...(x.chats || []), ...r.chats];
      if (r.next && (!x.next || r.next.start < x.next.start)) x.next = r.next;
      if (r.contact) x.contact = { ...x.contact, ...Object.fromEntries(Object.entries(r.contact).filter(([, v]) => v)) };
    }
    const keys = [...new Set(keysOf(x))];
    if (!keys.length) {   // a one-word name only (e.g. a Messenger chat "Pašky"): keyed by the chat or the name itself
      const k = x.chats?.[0]?.id ? "chat:" + x.chats[0].id : x.names[0] ? "name:" + fold(clean(x.names[0])) : null;
      if (!k) continue;
      keys.push(k);
    }
    const st = stateOf(keys);
    if (!x.adds && !st) continue;
    if (st?.hidden) continue;
    const name = st?.name || (personLike(x.contact?.name || "") ? tidyName(x.contact.name) : pickName(x.names)) || x.whatsapp?.chat
      || x.emails.map(nameFromEmail).find(Boolean) || x.emails[0] || x.phones[0];
    if (!name || isMe(name)) continue;
    x.emails = [...new Set(x.emails.map((e) => e.toLowerCase()))];
    x.phones = [...new Set(x.phones)];
    x.meetings = dedupe(x.meetings, (m) => m.path || m.title + m.date).sort((a, b) => b.date.localeCompare(a.date));
    x.company = x.contact?.company || companyOf(x.emails);
    const chatsBy = dedupe(x.chats || [], (c) => c.id).sort((a, b) => b.last.localeCompare(a.last));
    const lasts = [
      x.whatsapp?.last && { channel: "WhatsApp", date: x.whatsapp.last },
      x.mail?.last && { channel: "E-mail", date: x.mail.last.slice(0, 10) },
      ...chatsBy.map((c) => ({ channel: c.network, date: c.last })),
      x.meetings[0] && x.meetings[0].date <= today() && { channel: "Meeting", date: x.meetings[0].date },
    ].filter(Boolean).sort((a, b) => b.date.localeCompare(a.date));
    const last = lasts[0] || null;
    const since = daysSince(last?.date);
    const every = st?.every || s.every_days;
    const score = Math.min(x.whatsapp?.messages || 0, 400) / 20 + (x.mail?.sent || 0) * 1.5 + (x.mail?.received || 0) * 0.3
      + x.meetings.length * 4 + chatsBy.length * 2;
    const promises = (st?.promises || []).filter((q) => !q.done);
    stById.set(keys[0], st);
    people.push({
      id: keys[0], keys, name, aliases: [...new Set(x.names.map(clean).filter((n) => n && !n.includes("@") && !looksNumber(n)))].slice(0, 5),
      company: x.company || null, business: st?.business || guessBusiness(x), business_guessed: !st?.business,
      emails: x.emails.slice(0, 6), phones: x.phones.slice(0, 4),
      birthday: st?.birthday || x.contact?.birthday || null, birthday_source: st?.birthday ? "ručne" : x.contact?.birthday ? "Kontakty" : null,
      last: last && { ...last, days: since }, channels: lasts.slice(0, 6),
      whatsapp: x.whatsapp || null,
      mail: x.mail ? { sent: x.mail.sent, received: x.mail.received, last: x.mail.last, last_subject: x.mail.last_subject } : null,
      chats: chatsBy.slice(0, 4),
      meetings: x.meetings.slice(0, 8), next_meeting: x.next || null,
      groups: [...new Set(x.groups)].slice(0, 6),
      follow: !!st?.follow, every, note: st?.note || "", promises_open: promises.length, linked: !!st?.links?.length,
      due: !!st?.follow && (since == null || since >= every),
      score: Math.round(score * 10) / 10,
    });
  }
  people.sort((a, b) => (b.last?.date || "").localeCompare(a.last?.date || "") || b.score - a.score);

  // celebrations, linked to people: by the contact's phone or name, a birthday name you assigned (Priradiť), the same or a
  // similar name ("Silvia Eva Kráľová" is "Silvia Kráľová"), or a single word that starts one name only ("Mamina")
  const byKey = new Map(people.flatMap((x) => x.keys.map((k) => [k, x.id])));
  const words = (n) => fold(clean(n)).replace(/[^a-z ]/g, " ").replace(/\s+/g, " ").trim();
  const matchWho = (who) => {
    const f = words(who);
    if (!f) return [];
    const mine = people.filter((x) => (stById.get(x.id)?.birthday_names || []).includes(f));
    if (mine.length) return mine.map((x) => x.id);
    if (byKey.get("name:" + f)) return [byKey.get("name:" + f)];
    const w = f.split(" ");
    const near = people.filter((x) => { const v = words(x.name).split(" "); return (v.length >= 2 && v.every((y) => w.includes(y))) || (w.length >= 2 && w.every((y) => v.includes(y))); });
    if (near.length === 1) return [near[0].id];
    if (w.length === 1) { const pre = people.filter((x) => words(x.name).startsWith(f + " ")); if (pre.length === 1) return [pre[0].id]; }
    return [];
  };
  const party = (celeb || []).map((c) => {
    let ids = [...new Set(c.contacts.flatMap((k) => keysOf({ phones: [k.phone], names: [k.name] })).map((k) => byKey.get(k)).filter(Boolean))];
    if (!ids.length && c.kind === "narodeniny") ids = matchWho(c.who);
    return { date: c.date, kind: c.kind, who: c.who, age: c.age ?? null, contacts: c.contacts, people: ids, source: c.source || null };
  }).filter((c) => !isMe(c.who) && (c.kind === "narodeniny" || c.contacts.length || c.people.length));   // every birthday; a name day only of people you know
  // birthdays you set by hand, unless a calendar has them already
  const end = addDays(today(), days);
  for (const x of people.filter((y) => stById.get(y.id)?.birthday)) {
    const b = stById.get(x.id).birthday, md = b.slice(5);
    for (const y of [+today().slice(0, 4), +today().slice(0, 4) + 1]) {
      const d = `${y}-${md}`;
      if (d >= today() && d < end && !party.some((c) => c.kind === "narodeniny" && c.date === d && c.people.includes(x.id)))
        party.push({ date: d, kind: "narodeniny", who: x.name, age: b.startsWith("0000") ? null : y - +b.slice(0, 4), contacts: [], people: [x.id], source: "ručne" });
    }
  }
  party.sort((a, b) => a.date.localeCompare(b.date) || a.kind.localeCompare(b.kind));
  for (const c of party) for (const id of c.people) {
    const x = people.find((y) => y.id === id);
    if (!x) continue;
    if (!x.celebration && Date.parse(c.date) - Date.parse(today()) <= 14 * 86400000) x.celebration = { date: c.date, kind: c.kind };   // the gift icon: next two weeks
    if (c.kind === "narodeniny" && !x.birthday) { x.birthday = (c.age != null ? `${+c.date.slice(0, 4) - c.age}` : "0000") + c.date.slice(4); x.birthday_source = c.source || "kalendár"; }
  }

  const fading = people.filter((x) => !x.follow && x.score >= 8 && x.last && x.last.days >= s.fading_days && x.last.days <= 400)
    .sort((a, b) => b.score - a.score).slice(0, 20).map((x) => x.id);
  const out = { generated_at: new Date().toISOString(), settings: { every_days: s.every_days, fading_days: s.fading_days, sources: s.sources, crm: s.crm }, sources,
    counts: { people: people.length, followed: people.filter((x) => x.follow).length, due: people.filter((x) => x.due).length },
    due: people.filter((x) => x.due).sort((a, b) => (b.last?.days ?? 9999) - (a.last?.days ?? 9999)).map((x) => x.id),
    fading, celebrations: party, people };
  writeJSON(LAST, out);
  return out;
}

const addDays = (d, n) => { const x = new Date(`${d}T12:00:00`); x.setDate(x.getDate() + n); return x.toLocaleDateString("sv-SE"); };

// ---- celebrations -----------------------------------------------------------------------------------------------------
// The Slovak calendar of names (official names only, bold on en.wikipedia.org/wiki/Name_days_in_Slovakia, checked against the
// Meniny calendar; two vandalised entries removed). The Meniny calendar subscription covers two weeks only, this the rest.
const NAMEDAYS = JSON.parse(fs.readFileSync(new URL("./namedays-sk.json", import.meta.url), "utf8"));
const BDAY = /narodenin\p{L}*|🎂|birthday|b-?day/iu;

/** Birthdays and name days of the next `days` days: the Narodeniny calendar and contacts' birthdays (celebrations.js), a
 *  birthday written in any other calendar ("Mamina narodeniny", "Rudi narodeniny 🎂"), the Meniny calendar and after it the
 *  calendar of names, for contacts with that first name. */
async function yearOfCelebrations(days) {
  const [base, events, all] = await Promise.all([
    celebrations.upcoming({ days }),
    calendar.events({ from: today(), days, limit: 5000 }).then((r) => r.events).catch(() => []),
    celebrations.contacts(),
  ]);
  const items = base.map((c) => ({ ...c, source: c.kind === "meniny" ? "Meniny" : "Narodeniny" }));
  for (const e of events) {
    if (!BDAY.test(e.title || "") || ["Narodeniny", "Meniny"].includes(e.calendar)) continue;
    const who = clean(e.title.replace(new RegExp(BDAY.source, "giu"), "").replace(/[^\p{L}\s'’-]/gu, " ").replace(/\s+/g, " "));
    if (who) items.push({ date: e.start.slice(0, 10), kind: "narodeniny", who, contacts: [], source: e.calendar });
  }
  const covered = items.filter((c) => c.kind === "meniny").map((c) => c.date).sort().at(-1) || addDays(today(), -1);
  const full = (c) => [c.given, c.family].filter(Boolean).join(" ");
  for (let i = 0; i < days; i++) {
    const d = addDays(today(), i);
    if (d <= covered) continue;
    for (const name of NAMEDAYS[d.slice(5)] || []) {
      const f = fold(name);
      const cs = all.filter((c) => fold(c.given) === f || fold(c.nickname || "") === f)
        .map((c) => ({ name: full(c) || c.nickname, phone: c.phones?.[0], ...(c.company ? { company: c.company } : {}) }));
      if (cs.length) items.push({ date: d, kind: "meniny", who: name, contacts: cs, source: "kalendár mien" });
    }
  }
  return items.sort((a, b) => a.date.localeCompare(b.date));
}

const looksNumber = (s) => /^\+?[\d\s-]{8,}$/.test(clean(s));
const dedupe = (list, key) => { const seen = new Set(); return list.filter((x) => { const k = key(x); return !seen.has(k) && seen.add(k); }); };
/** A chat name that looks like a person: two or more words of letters (not "Alza.sk", "SAVICKI" or a number). */
const personLike = (n) => /^\p{L}[\p{L}'’-]*(\s+\p{L}[\p{L}.'’-]*)+$/u.test(clean(n));
/** The best real-looking name: plain "Name Surname" over "Surname, Company" or "SURNAME Name", then with diacritics, then longest. */
function pickName(names) {
  const ok = names.map(clean).filter((n) => n && !n.includes("@") && !looksNumber(n));
  const rank = (n) => (personLike(n) ? 4 : 0) + (n.includes(" ") ? 2 : 0) + (n !== n.toUpperCase() && !/\p{Lu}{3,}/u.test(n) ? 1 : 0);
  return tidyName(ok.sort((a, b) => rank(b) - rank(a) || (/[áäčďéíľĺňóôŕšťúýž]/i.test(b) - /[áäčďéíľĺňóôŕšťúýž]/i.test(a)) || a.length - b.length)[0]);
}
/** "jan.novak@firma.sk" → "Jan Novak" (no accents, but better than the address); "salescz@…" → "". */
export function nameFromEmail(e) {
  const m = String(e || "").toLowerCase().match(/^([a-z]{2,})[._]([a-z]{2,})@/);
  return m ? `${m[1][0].toUpperCase()}${m[1].slice(1)} ${m[2][0].toUpperCase()}${m[2].slice(1)}` : "";
}
/** Outlook style "HORVÁTHOVÁ Zuzana" → "Zuzana Horváthová"; "Ondráš, J. (Jakub)" stays as it is. */
export function tidyName(n) {
  const m = String(n || "").match(/^(\p{Lu}[\p{Lu}'’-]+)\s+(\p{Lu}\p{Ll}[\p{L}'’-]*)$/u);
  return m ? `${m[2]} ${m[1].charAt(0)}${m[1].slice(1).toLocaleLowerCase("sk")}` : n;
}
function companyOf(emails) {
  const d = emails.map((e) => e.split("@")[1]).find((v) => v && !FREEMAIL.test(v));
  return d || null;
}

// ---- one person -------------------------------------------------------------------------------------------------------

function lastOverview() { return readJSON(LAST, null); }

/** A person from the last overview by id, key, name, e-mail or phone. */
export async function find(query) {
  let o = lastOverview();
  if (!o) o = await overview();
  const q = String(query || "").trim(), f = fold(q), digits = normPhone(q);
  return o.people.find((x) => x.id === q || x.keys.includes(q))
    || (digits && o.people.find((x) => x.phones.includes(digits)))
    || o.people.find((x) => x.emails.includes(q.toLowerCase()))
    || o.people.find((x) => fold(x.name) === f)
    || o.people.find((x) => x.aliases.some((a) => fold(a).includes(f)) || fold(x.name).includes(f))
    || null;
}

const splitLine = (l) => { const [at, who, ...rest] = String(l).split(" | "); return { at, me: who === "me" || /^(ja|me|you)$/i.test(who || ""), who, text: rest.join(" | ") }; };

async function personMail(x) {
  if (!x.emails.length || !fs.existsSync(COURIER_DB)) return [];
  const esc = (s) => s.replace(/'/g, "''");
  const cond = x.emails.map((e) => `lower(m.from_addr) = '${esc(e)}' OR lower(m.to_line) LIKE '%${esc(e)}%' OR lower(m.cc_line) LIKE '%${esc(e)}%'`).join(" OR ");
  const rows = await sql(COURIER_DB, `SELECT m.id, m.message_id mid, m.subject, m.from_name, m.from_addr, m.snippet, m.date, f.role
    FROM messages m JOIN folders f ON f.account_id = m.account_id AND f.path = m.folder
    WHERE (${cond}) AND f.role NOT IN ('trash', 'junk') ORDER BY m.date DESC LIMIT 60`);
  return dedupe(rows, (r) => r.mid || r.id).slice(0, 15).map((r) => ({
    id: r.id, subject: r.subject || "(bez predmetu)", from: clean(r.from_name) || r.from_addr, sent: r.role === "sent",
    date: new Date(r.date * 1000).toISOString(), snippet: String(r.snippet || "").replace(/[_=*~-]{4,}/g, " ").replace(/\s+/g, " ").trim().slice(0, 180), url: `courier://message/${r.id}` }));
}

async function todoist(name) {
  const accounts = [{ server: "todoist", label: "Kudosky" }, { server: "todoist-10t", label: "10T" }];
  const words = name.split(/\s+/);
  const queries = [...new Set([name, words.length > 1 ? words.at(-1) : null].filter((w) => w && w.length > 3))];
  const got = await Promise.all(accounts.flatMap(({ server, label }) => queries.map(async (q) => {
    try {
      const r = await callTool(server, "find-tasks", { searchText: q, limit: 20 }, 20000);
      return (JSON.parse(resultText(r).split("\n")[0]).tasks || []).filter((t) => !t.checked)
        .map((t) => ({ id: t.id, content: t.content, due: t.dueDate || null, priority: t.priority, account: label,
          url: `todoist://task?id=${t.id}` }));
    } catch { return []; }
  })));
  return dedupe(got.flat(), (t) => t.id).sort((a, b) => (a.due || "9").localeCompare(b.due || "9")).slice(0, 15);
}

// ---- work CRM (optional) ----------------------------------------------------------------------------------------------
// Set in the app (Zdroje › Pracovné CRM), stored in data/ludia.json "crm": { label, server, tool, args, groups }. Any read
// tool of any MCP server Brain knows; args is a JSON template where {email} and {name} are the person's. Nothing about a
// particular company is in the code: change jobs, change the setting.

const crmFor = (x) => { const c = settings().crm; return c?.server && c?.tool && x.emails.length && (c.groups || ["work"]).includes(x.business) ? c : null; };

/** Read tools of every connected MCP server, for picking the CRM in the app. */
export function crmTools() {
  return Object.entries(catalog.cached()).map(([server, v]) => ({ server,
    tools: (v.tools || []).filter((t) => catalog.kind(t) === "read" && !/propose|commit|send|write|update|delete|create/i.test(t.name)).map((t) => ({ name: t.name, description: String(t.description || "").slice(0, 160) })) }))
    .filter((x) => x.tools.length).sort((a, b) => a.server.localeCompare(b.server));
}

async function crmLookup(x, c) {
  const email = x.emails.find((e) => !FREEMAIL.test(e.split("@")[1] || "")) || x.emails[0];
  const fill = (t) => String(t || "{}").replaceAll("{email}", email).replaceAll("{name}", x.name.replace(/"/g, ""));
  const r = await callTool(c.server, c.tool, JSON.parse(fill(c.args)), 15000);
  const text = resultText(r);
  if (r.isError) throw new Error(text.slice(0, 200));
  let j; try { j = JSON.parse(text); } catch { return text.trim() ? [{ name: text.trim().slice(0, 300) }] : []; }
  const list = [j, j?.result?.data, j?.data, j?.items, j?.result, j?.contacts, j?.results].find(Array.isArray) || (j && typeof j === "object" ? [j] : []);
  const pick = (o, ...k) => { for (const key of k) { const v = key.split(".").reduce((a, p) => a?.[p], o); if (v != null && v !== "" && typeof v !== "object") return String(v); } return null; };
  return list.slice(0, 5).map((o) => ({ name: pick(o, "title", "name", "full_name", "fullName", "displayName") || email,
    detail: pick(o, "account.title", "account.name", "company", "organization", "company.name", "position", "role"), email: pick(o, "email") }));
}

/** Everything about one person: recent WhatsApp, Beeper and mail, meetings, open tasks, notes, your note and promises. */
export async function person({ id, query } = {}) {
  const x = await find(id || query);
  if (!x) return { error: `Človek „${id || query}“ sa v Ľuďoch nenašiel.` };
  status(`Ľudia: skladám ${x.name}`);
  const sources = {};
  const safe = (name, pr) => Promise.resolve().then(() => pr()).then((r) => { sources[name] = { ok: true }; return r; })
    .catch((e) => { sources[name] = { ok: false, error: String(e.message || e).slice(0, 200) }; return []; });
  const [whatsapp, chats, mails, tasks, crmItems] = await Promise.all([
    x.whatsapp ? safe("whatsapp", () => wa.read({ chat: x.whatsapp.chat, limit: 12 }).then((r) => r.messages.map(splitLine))) : [],
    safe("beeper", () => Promise.all(x.chats.slice(0, 2).map((c) => beeper.read({ chat: c.id, network: "all", limit: 8, ocr: false })
      .then((r) => ({ id: c.id, network: c.network, messages: r.messages.map(splitLine) }))))),
    safe("mail", () => personMail(x)),
    safe("todoist", () => todoist(x.name)),
    crmFor(x) ? safe("crm", () => crmLookup(x, crmFor(x))) : [],
  ]);
  const st = readJSON(STATE, { people: [] }).people.find((e) => e.keys.some((k) => x.keys.includes(k)));
  return { generated_at: new Date().toISOString(), person: x, sources, whatsapp, chats, mails, tasks, crm: crmFor(x) ? { label: crmFor(x).label || "Pracovné CRM", items: crmItems } : null,
    notes: recall(x.name, 5).map((n) => ({ text: String(n.text || n.body || n.content || JSON.stringify(n)).slice(0, 400), topic: n.topic || null })),
    promises: st?.promises || [] };
}

// ---- topic search ------------------------------------------------------------------------------------------------------

/** Who you talked with about something: mail in Courier (subject and text), WhatsApp, Beeper chats and meeting titles,
 *  as people from the last overview with the matching lines, most hits first. Diacritics and case don't matter. */
export async function search({ query, limit = 40 } = {}) {
  const o = lastOverview() || await overview();
  const words = fold(query).split(/\s+/).filter((w) => w.length > 1);
  if (!words.length) return { query, people: [] };
  const has = (t) => { const f = fold(t); return words.every((w) => f.includes(w)); };
  const byKey = new Map(o.people.flatMap((x) => x.keys.map((k) => [k, x])));
  const byChat = new Map(o.people.flatMap((x) => [...(x.whatsapp ? [["wa:" + fold(x.whatsapp.chat), x]] : []), ...x.chats.map((c) => ["bp:" + c.id, x])]));
  const byName = (n) => byKey.get("name:" + fold(clean(n)).replace(/[^a-z ]/g, " ").replace(/\s+/g, " ").trim());
  const hits = new Map();
  const hit = (x, h) => { if (!x) return; const e = hits.get(x.id) || { person: x, hits: [] }; e.hits.push(h); hits.set(x.id, e); };
  const sources = {};
  const safe = (name, fn) => Promise.resolve().then(fn).then(() => { sources[name] = { ok: true }; }).catch((e) => { sources[name] = { ok: false, error: String(e.message || e).slice(0, 160) }; });
  const snip = (t) => { const f = String(t || "").replace(/\s+/g, " "), i = fold(f).indexOf(words[0]); return (i > 60 ? "…" + f.slice(i - 50, i + 130) : f.slice(0, 180)).trim(); };

  status(`Ľudia: hľadám „${query}“ v mailoch, WhatsAppe a Beeperi`);
  await Promise.all([
    safe("mail", async () => {
      if (!fs.existsSync(COURIER_DB)) return;
      const like = words.map((w) => `(m.subject LIKE '%${w.replace(/[^a-z0-9]/g, "_")}%' OR m.body_text LIKE '%${w.replace(/[^a-z0-9]/g, "_")}%' OR m.snippet LIKE '%${w.replace(/[^a-z0-9]/g, "_")}%')`).join(" AND ");
      const rows = await sql(COURIER_DB, `SELECT m.id, m.message_id mid, m.subject, m.from_addr, m.to_line, m.cc_line, m.date, coalesce(m.body_text, m.snippet, '') text, f.role
        FROM messages m JOIN folders f ON f.account_id = m.account_id AND f.path = m.folder
        WHERE coalesce(m.category, 'people') = 'people' AND f.role NOT IN ('trash', 'junk') AND ${like} ORDER BY m.date DESC LIMIT 400`);
      for (const r of dedupe(rows, (r) => r.mid || r.id)) {
        if (!has(`${r.subject} ${r.text}`)) continue;
        const who = r.role === "sent" ? parseAddrs(`${r.to_line || ""},${r.cc_line || ""}`).map((a) => a.email) : [String(r.from_addr).toLowerCase()];
        const h = { channel: "E-mail", date: new Date(r.date * 1000).toISOString(), text: `${r.subject || ""} · ${snip(has(r.subject) ? r.text || r.subject : r.text)}`, url: `courier://message/${r.id}` };
        for (const e of new Set(who)) hit(byKey.get("mail:" + e), h);
      }
    }),
    safe("whatsapp", async () => {
      for (const r of await wa.search({ query, limit: 200 })) {
        const [at, who, ...rest] = r.line.split(" | ");
        const x = byChat.get("wa:" + fold(r.chat)) || (who !== "me" ? byName(who) : null);
        hit(x, { channel: "WhatsApp", date: at, text: (byChat.get("wa:" + fold(r.chat)) ? "" : `${r.chat}: `) + snip(rest.join(" | ")) });
      }
    }),
    safe("beeper", async () => {
      if (!beeper.connected()) return;
      const r = await beeper.search({ query, network: "all", limit: 20 });
      for (const m of r.messages || r.hits || r || []) {
        const [at, who, ...rest] = String(m.line || "").split(" | ");
        const x = (m.chatID && byChat.get("bp:" + m.chatID)) || o.people.find((p) => p.chats.some((c) => fold(m.chat || "") && fold(p.name) === fold(m.chat))) || (who !== "me" ? byName(who) : null);
        hit(x, { channel: "Správy", date: at, text: snip(rest.join(" | ")) });
      }
    }),
    safe("meetings", async () => {
      for (const x of o.people) for (const m of x.meetings) if (has(m.title)) hit(x, { channel: "Meeting", date: m.date, text: m.title, url: m.path ? "file://" + encodeURI(m.path) : null });
    }),
  ]);
  for (const e of hits.values()) e.hits = dedupe(e.hits, (h) => fold(h.text).replace(/[^a-z0-9]/g, "").slice(-60));   // Beeper also bridges WhatsApp
  const people = [...hits.values()].map((e) => ({ id: e.person.id, name: e.person.name, count: e.hits.length,
    last: e.hits.map((h) => String(h.date || "")).sort().at(-1) || null,
    hits: e.hits.sort((a, b) => String(b.date).localeCompare(String(a.date))).slice(0, 4) }))
    .sort((a, b) => b.count - a.count || String(b.last).localeCompare(String(a.last))).slice(0, limit);
  return { query, sources, people };
}

// ---- your own additions -----------------------------------------------------------------------------------------------

/** Change what you keep about a person: follow, every (days), note, business, hidden, name; promise (adds one),
 *  promise_done / promise_undo / promise_delete (by promise id). Local only (data/ludia.json). */
export async function update({ id, query, ...patch } = {}) {
  const x = await find(id || query);
  if (!x) return { error: `Človek „${id || query}“ sa v Ľuďoch nenašiel.` };
  const state = readJSON(STATE, { people: [] });
  if (patch.merge_with) return merge({ id: x.id, other: patch.merge_with });
  if (patch.split) return split({ id: x.id });
  let e = state.people.find((y) => [...y.keys, ...(y.links || [])].some((k) => x.keys.includes(k)));
  if (!e) state.people.push((e = { keys: x.keys, promises: [] }));
  if (!e.links?.length) e.keys = [...new Set([...e.keys, ...x.keys])];
  e.label = x.name;
  for (const k of ["follow", "every", "note", "business", "hidden", "name"]) {
    if (patch[k] === undefined) continue;
    if (patch[k] === null || patch[k] === "") delete e[k]; else e[k] = k === "every" ? Math.max(1, Number(patch[k])) : patch[k];
  }
  e.promises ||= [];
  if (patch.promise) e.promises.push({ id: Date.now().toString(36), text: String(patch.promise).trim(), date: today(), done: false, ...(patch.due ? { due: patch.due } : {}) });
  for (const [k, done] of [["promise_done", true], ["promise_undo", false]]) {
    const q = e.promises.find((y) => y.id === patch[k]); if (q) { q.done = done; q.done_at = done ? today() : undefined; }
  }
  if (patch.promise_delete) e.promises = e.promises.filter((y) => y.id !== patch.promise_delete);
  if (patch.contacted) e.contacted = today();
  if (patch.birthday !== undefined) { if (patch.birthday) e.birthday = String(patch.birthday).slice(0, 10); else delete e.birthday; }   // "YYYY-MM-DD", "0000-MM-DD" (year unknown) or null
  if (patch.birthday_name) e.birthday_names = [...new Set([...(e.birthday_names || []), fold(clean(patch.birthday_name)).replace(/[^a-z ]/g, " ").replace(/\s+/g, " ").trim()])];
  if (patch.birthday_name_remove) e.birthday_names = (e.birthday_names || []).filter((n) => n !== patch.birthday_name_remove);
  writeJSON(STATE, state);
  appendLine(p("audit.jsonl"), { ludia: x.name, patch });
  // keep the cached overview in step so the app and `person` see it right away
  const o = lastOverview();
  const y = o?.people.find((z) => z.id === x.id);
  if (y) {
    if (patch.hidden) o.people = o.people.filter((z) => z.id !== x.id);
    else {
      y.follow = !!e.follow; y.every = e.every || settings().every_days; y.note = e.note || "";
      if (e.name) y.name = e.name;
      if (e.business) { y.business = e.business; y.business_guessed = false; }
      y.promises_open = e.promises.filter((q) => !q.done).length;
      y.due = y.follow && (y.last?.days == null || y.last.days >= y.every);
    }
    o.due = o.people.filter((z) => z.due).sort((a, b) => (b.last?.days ?? 9999) - (a.last?.days ?? 9999)).map((z) => z.id);
    o.fading = o.fading.filter((fid) => fid !== x.id || !y?.follow);
    writeJSON(LAST, o);
  }
  return { ok: true, id: x.id, name: x.name, state: e };
}

/** Two records are one person (a duplicate): `other` is merged into `id`. Your note, promises, follow and business of both
 *  are kept (id's win where both have one); the name stays id's. Saved as links, so it holds on every refresh; split undoes it. */
export async function merge({ id, other }) {
  const a = await find(id), b = await find(other);
  if (!a || !b) return { error: `Človek „${!a ? id : other}“ sa v Ľuďoch nenašiel.` };
  if (a.id === b.id) return { error: "To je ten istý človek." };
  const state = readJSON(STATE, { people: [] });
  const mine = (x) => state.people.filter((y) => [...y.keys, ...(y.links || [])].some((k) => x.keys.includes(k)));
  const ea = mine(a), eb = mine(b).filter((y) => !ea.includes(y));
  const e = ea[0] || { keys: a.keys, promises: [] };
  if (!ea.length) state.people.push(e);
  e.keys = [...new Set([...e.keys, ...a.keys])];
  e.links = [...new Set([...(e.links || []), ...b.keys, ...ea.slice(1).concat(eb).flatMap((y) => [...y.keys, ...(y.links || [])])])].filter((k) => !e.keys.includes(k));
  e.merged = [...(e.merged || []), { name: b.name, keys: b.keys, at: today() }];
  e.name ||= a.name;
  e.label = a.name;
  for (const y of [...ea.slice(1), ...eb]) {
    e.note = [e.note, y.note].filter(Boolean).join("\n");
    e.promises = [...(e.promises || []), ...(y.promises || [])];
    if (y.follow && !e.follow) { e.follow = true; e.every = y.every; }
    e.business ||= y.business;
    state.people.splice(state.people.indexOf(y), 1);
  }
  if (!e.note) delete e.note;
  writeJSON(STATE, state);
  appendLine(p("audit.jsonl"), { ludia_merge: [a.name, b.name] });
  const o = await overview();
  const merged = o.people.find((x) => x.keys.some((k) => a.keys.includes(k)));
  return { ok: true, id: merged?.id, name: merged?.name, merged: b.name };
}

/** Undo every merge of this person: the records go back to how Brain matches them by itself. */
export async function split({ id }) {
  const x = await find(id);
  if (!x) return { error: `Človek „${id}“ sa v Ľuďoch nenašiel.` };
  const state = readJSON(STATE, { people: [] });
  const e = state.people.find((y) => [...y.keys, ...(y.links || [])].some((k) => x.keys.includes(k)));
  if (!e?.links?.length) return { error: `${x.name} nie je zlúčený.` };
  // a name picked when merging (theirs or yours) goes too: each record gets its own name back
  if (e.name === e.label || (e.merged || []).some((m) => m.name === e.name) || e.name_from_merge) delete e.name;
  delete e.links; delete e.merged; delete e.name_from_merge;
  // nothing else kept about them (the entry was only the merge): leave no empty entry behind
  if (!e.follow && !e.note && !e.business && !e.hidden && !e.name && !(e.promises || []).length) state.people.splice(state.people.indexOf(e), 1);
  writeJSON(STATE, state);
  appendLine(p("audit.jsonl"), { ludia_split: x.name });
  const o = await overview();
  const back = o.people.find((y) => y.keys.some((k) => e.keys.includes(k)));
  return { ok: true, id: back?.id, name: back?.name };
}

/** Settings from the app: what each source does ({ whatsapp: "add" | "enrich" | "off", … }) and every_days / fading_days.
 *  Takes effect on the next overview. */
export function setSources(patch = {}) {
  const state = readJSON(STATE, { people: [] });
  state.sources = { ...(state.sources || {}) };
  for (const k of ["every_days", "fading_days"]) if (patch[k] !== undefined) { state[k] = Math.max(1, Number(patch[k]) || DEFAULTS[k]); delete patch[k]; }
  if (patch.crm !== undefined) {   // null turns it off
    const c = patch.crm; delete patch.crm;
    if (!c) delete state.crm;
    else {
      if (!c.server || !c.tool) throw new Error("CRM: chýba server alebo nástroj");
      JSON.parse(String(c.args || "{}").replaceAll("{email}", "a@b.c").replaceAll("{name}", "A B"));   // must be valid JSON
      state.crm = { label: c.label || "Pracovné CRM", server: c.server, tool: c.tool, args: c.args || "{}", groups: c.groups?.length ? c.groups : ["work"] };
    }
  }
  for (const [k, v] of Object.entries(patch)) {
    if (!SOURCES.includes(k)) throw new Error(`neznámy zdroj ${k} (${SOURCES.join(", ")})`);
    if (!["add", "enrich", "off"].includes(v)) throw new Error(`${k}: add, enrich alebo off`);
    state.sources[k] = v;
  }
  writeJSON(STATE, state);
  const s = settings();
  return { sources: s.sources, every_days: s.every_days, fading_days: s.fading_days, crm: s.crm };
}

/** Short version for Claude: who to get in touch with, who you're losing touch with, celebrations, open promises. */
export async function compact({ fresh = false } = {}) {
  const o = (!fresh && lastOverview() && Date.now() - Date.parse(lastOverview().generated_at) < 3 * 3600000) ? lastOverview() : await overview();
  const byId = new Map(o.people.map((x) => [x.id, x]));
  const row = (x) => ({ name: x.name, company: x.company, business: x.business, last: x.last ? `${x.last.channel}, pred ${x.last.days} d (${x.last.date})` : "nikdy",
    every: x.follow ? x.every : undefined, note: x.note || undefined, promises_open: x.promises_open || undefined });
  const state = readJSON(STATE, { people: [] });
  return { generated_at: o.generated_at, counts: o.counts,
    ozvi_sa: o.due.map((id) => byId.get(id)).filter(Boolean).map(row),
    zabudas: o.fading.map((id) => byId.get(id)).filter(Boolean).slice(0, 10).map(row),
    oslavy: o.celebrations.slice(0, 15).map((c) => ({ date: c.date, kind: c.kind, who: c.people.map((id) => byId.get(id)?.name).filter(Boolean)[0] || c.who, age: c.age || undefined })),
    slubene: state.people.flatMap((e) => (e.promises || []).filter((q) => !q.done).map((q) => ({ who: e.name || e.label, text: q.text, since: q.date, due: q.due }))),
    sources: o.sources };
}
