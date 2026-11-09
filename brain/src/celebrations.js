// Birthdays and name days, matched with the user's contacts (macOS Contacts = the phone's iCloud contacts).
// Sources: the "Narodeniny" calendar (Facebook birthdays, "🎂 Name Surname"), birthdays saved on contacts, and the
// "Meniny" calendar ("Denis, Denisa (meniny)", a subscription that always covers the next two weeks).
// Each morning the brief lists today's and Brain adds one Reminders task per celebration that matches a contact.
import { helper, events } from "./calendar.js";
import { fold } from "./notes.js";
import { p } from "./paths.js";
import * as reminders from "./reminders.js";
import { appendLine, config, readJSON, writeJSON } from "./store.js";
import { status } from "./ui.js";
import { readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const CONTACTS = p("contacts.json");     // { at, contacts: [...] } — refreshed every 12 hours, or sooner when Contacts change
const STATE = p("celebrations.json");    // { reminded: ["2026-11-04|meniny|Karol", ...] }
const DEFAULTS = { birthday_calendars: ["Narodeniny"], nameday_calendars: ["Meniny"], list: "To do", remind_at: "09:00",
                   // "contacts": a reminder only when the person is in your contacts; "all": every birthday too
                   remind: "contacts" };
const settings = () => ({ ...DEFAULTS, ...(config().celebrations || {}) });
const today = () => new Date().toLocaleDateString("sv-SE");

/** When the macOS Contacts databases last changed (the main one and every synced source), 0 if unreadable. */
export function contactsChangedAt(dir = join(homedir(), "Library/Application Support/AddressBook")) {
  const files = [join(dir, "AddressBook-v22.abcddb")];
  try { for (const s of readdirSync(join(dir, "Sources"))) files.push(join(dir, "Sources", s, "AddressBook-v22.abcddb")); } catch {}
  let t = 0;
  for (const f of files) for (const x of [f, f + "-wal"]) { try { t = Math.max(t, statSync(x).mtimeMs); } catch {} }
  return t;
}

export async function contacts({ maxAgeH = 12 } = {}) {
  const c = readJSON(CONTACTS, null);
  const at = c ? Date.parse(c.at) : 0;
  // a contact saved since the last read (e.g. a new number) must show up now, not after 12 hours
  if (c && Date.now() - at < maxAgeH * 3600000 && contactsChangedAt() <= at) return c.contacts;
  status("Čítam kontakty");
  const list = await helper(["contacts"], 120000);
  writeJSON(CONTACTS, { at: new Date().toISOString(), contacts: list });
  return list;
}

const full = (c) => [c.given, c.family].filter(Boolean).join(" ");
const out = (c) => ({ name: full(c) || c.nickname || c.company, phone: c.phones?.[0], ...(c.company ? { company: c.company } : {}) });

function byName(all, name) {   // "Silvia Eva Kráľová" → contacts whose first and last name are both in it (middle names, any order)
  const words = new Set(fold(name).replace(/[^a-z ]/g, " ").split(/\s+/).filter(Boolean));
  return all.filter((c) => c.given && c.family && words.has(fold(c.given)) && fold(c.family).split(/[\s-]+/).every((w) => words.has(w)));
}

function byGiven(all, given) {   // "Karol" → every contact whose first name (or nickname) is Karol
  const g = fold(given);
  return all.filter((c) => fold(c.given) === g || fold(c.nickname || "") === g);
}

/** Who celebrates from `from` for `days` days: [{ date, kind, who, contacts: [{ name, phone }] }]. */
export async function upcoming({ from = today(), days = 7 } = {}) {
  const s = settings();
  const [all, bdays, ndays] = await Promise.all([
    contacts(),
    events({ from, days, calendars: s.birthday_calendars, limit: 500 }).then((r) => r.events).catch(() => []),
    events({ from, days, calendars: s.nameday_calendars, limit: 500 }).then((r) => r.events).catch(() => []),
  ]);
  status(`Párujem oslávencov s ${all.length} kontaktmi`);
  const end = new Date(`${from}T12:00:00`); end.setDate(end.getDate() + days);
  const to = end.toLocaleDateString("sv-SE");
  const items = [];
  for (const e of bdays) {
    const who = e.title.replace(/^[^\p{L}]+/u, "").trim();
    items.push({ date: e.start.slice(0, 10), kind: "narodeniny", who, contacts: byName(all, who).map(out) });
  }
  // birthdays saved on a contact, unless the calendar already has them
  for (const c of all.filter((x) => x.birthday)) {
    const md = c.birthday.slice(5);
    for (let y = +from.slice(0, 4); y <= +to.slice(0, 4); y++) {
      const d = `${y}-${md}`;
      if (d >= from && d < to && !items.some((i) => i.kind === "narodeniny" && i.date === d && fold(i.who) === fold(full(c))))
        items.push({ date: d, kind: "narodeniny", who: full(c), contacts: [out(c)], ...(c.birthday.startsWith("0000") ? {} : { age: y - +c.birthday.slice(0, 4) }) });
    }
  }
  for (const e of ndays) {
    for (const name of e.title.replace(/\(meniny\)/i, "").split(/,| a /).map((x) => x.trim()).filter(Boolean))
      items.push({ date: e.start.slice(0, 10), kind: "meniny", who: name, contacts: byGiven(all, name).map(out) });
  }
  return items.sort((a, b) => a.date.localeCompare(b.date) || a.kind.localeCompare(b.kind));
}

/** Today's celebrations as Reminders tasks ("Napísať …"), each once. Runs with the morning brief. */
export async function remindToday() {
  const s = settings();
  const state = readJSON(STATE, { reminded: [] });
  const items = (await upcoming({ days: 1 })).filter((i) => i.contacts.length || (s.remind === "all" && i.kind === "narodeniny"));
  const added = [];
  for (const i of items) {
    const k = `${i.date}|${i.kind}|${i.who}`;
    if (state.reminded.includes(k)) continue;
    const people = i.contacts.length ? i.contacts : [{ name: i.who }];
    const title = i.kind === "meniny"
      ? `Napísať k meninám: ${people.map((c) => c.name).join(", ")}`
      : `Napísať k narodeninám: ${people[0].name}${i.age ? ` (${i.age})` : ""}`;
    const notes = people.map((c) => `${c.name}${c.phone ? ` · ${c.phone} · WhatsApp: https://wa.me/${c.phone.replace(/\D/g, "").replace(/^0/, "421")}` : ""}`).join("\n");
    await reminders.add({ title, list: s.list, due: `${i.date}T${s.remind_at}`, notes });
    state.reminded.push(k); added.push(title);
  }
  state.reminded = state.reminded.slice(-500);
  writeJSON(STATE, state);
  if (added.length) appendLine(p("audit.jsonl"), { celebrations: added });
  return added;
}
