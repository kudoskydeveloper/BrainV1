// Who's who: one profile per person, merged from WhatsApp (contacts and group members), email senders (Thunderbird
// digest) and meeting notes (attendees), matched by phone, email or name. Companies come from email domains.
import fs from "node:fs";
import path from "node:path";
import { KUDOSKY_MEETINGS } from "./fathom.js";
import { fold, recall } from "./notes.js";
import { p } from "./paths.js";
import { readJSON, writeJSON } from "./store.js";
import * as wa from "./whatsapp.js";

const GRAPH = p("people-graph.json");
const FREEMAIL = /^(gmail|googlemail|icloud|me|mac|yahoo|outlook|hotmail|live|seznam|centrum|azet|post|zoznam|proton|protonmail|atlas|email)\./;
const clean = (s) => String(s || "").replace(/[‪‬]/g, "").trim();
const looksLikeNumber = (s) => /^\+?[\d\s-]{8,}$/.test(clean(s));

function meetingPeople() {
  const out = [];
  let files; try { files = fs.readdirSync(KUDOSKY_MEETINGS).filter((f) => f.endsWith(".md")); } catch { return out; }
  for (const f of files) {
    const t = fs.readFileSync(path.join(KUDOSKY_MEETINGS, f), "utf8").slice(0, 3000);
    const title = t.split("\n")[0].replace(/^# /, ""), date = f.slice(0, 10);
    const line = (t.match(/\*\*(Attendees|With):\*\* (.+)/) || [])[2] || "";
    for (const part of line.split(/,(?![^<]*>)/)) {
      const email = (part.match(/<([^>]+)>/) || part.match(/([\w.+-]+@[\w-]+\.[\w.]+)/) || [])[1];
      const name = clean(part.replace(/<[^>]+>/, "").replace(/[\w.+-]+@[\w-]+\.[\w.]+/, ""));
      if (name || email) out.push({ name: name || undefined, email: email?.toLowerCase(), meeting: { title, date } });
    }
  }
  return out;
}

export async function buildPeople() {
  const people = [];   // { names:Set, emails:Set, phones:Set, whatsapp:{chat,messages,last}, groups:Set, meetings:[], email:{count,last_subject,last_date}, notes_contact:{role,company,note} }
  const byKey = new Map();
  const find = (keys) => keys.map((k) => byKey.get(k)).find(Boolean);
  const add = ({ name, email, phone }, fn) => {
    name = clean(name); if (looksLikeNumber(name)) { phone = phone || name.replace(/\D/g, ""); name = ""; }
    const keys = [phone && "tel:" + phone, email && "mail:" + email, name && name.includes(" ") && "name:" + fold(name)].filter(Boolean);
    if (!keys.length) return;
    let pr = find(keys);
    if (!pr) { pr = { names: new Set(), emails: new Set(), phones: new Set(), groups: new Set(), meetings: [] }; people.push(pr); }
    if (name) pr.names.add(name); if (email) pr.emails.add(email); if (phone) pr.phones.add(phone);
    for (const k of keys) byKey.set(k, pr);
    fn?.(pr);
  };

  // WhatsApp one-to-one chats and group members
  const rows = await wa.contactsAndMembers().catch(() => ({ contacts: [], members: [] }));
  for (const c of rows.contacts) add({ name: c.name, phone: c.phone }, (pr) => { pr.whatsapp = { messages: c.messages, last: c.last }; });
  for (const m of rows.members) add({ name: m.name, phone: m.phone }, (pr) => pr.groups.add(clean(m.group)));
  // email senders
  for (const e of Object.values(readJSON(p("people.json"), {}))) add({ name: e.name, email: e.email }, (pr) => { pr.mail = { count: e.count, last_date: e.last_date, last_subject: e.last_subject }; });
  // meeting attendees
  for (const m of meetingPeople()) add(m, (pr) => pr.meetings.push(m.meeting));
  // contacts found in Apple Notes (data/notes-contacts.json, written by the Notes cleanup)
  for (const c of readJSON(p("notes-contacts.json"), { contacts: [] }).contacts) {
    const seen = (pr) => { pr.notes_contact = { role: c.role, company: c.company, note: c.note }; };
    if (!c.phones.length) add({ name: c.name, email: c.email }, seen);
    for (const phone of c.phones) add({ name: c.name, email: c.email, phone }, seen);
  }

  const out = people.map((pr) => {
    const emails = [...pr.emails], domains = [...new Set(emails.map((e) => e.split("@")[1]).filter((d) => d && !FREEMAIL.test(d)))];
    return { name: [...pr.names].sort((a, b) => b.length - a.length)[0] || [...pr.phones][0] || emails[0], aliases: [...pr.names],
             emails, phones: [...pr.phones], companies: domains, whatsapp: pr.whatsapp, groups: [...pr.groups].slice(0, 12),
             meetings: pr.meetings.sort((a, b) => b.date.localeCompare(a.date)).slice(0, 10), mail: pr.mail, from_notes: pr.notes_contact };
  });
  writeJSON(GRAPH, { built: new Date().toISOString(), people: out });
  return { people: out.length, with_whatsapp: out.filter((x) => x.whatsapp || x.groups.length).length, with_email: out.filter((x) => x.mail).length,
           with_meetings: out.filter((x) => x.meetings.length).length };
}

/** Profiles matching a name, email, phone or company (domain), plus notes about them. */
export function who(query, limit = 5) {
  const g = readJSON(GRAPH, { people: [] });
  const q = fold(query).trim(), digits = query.replace(/\D/g, "");
  const score = (x) => {
    const names = x.aliases.map(fold);
    if (names.some((n) => n === q)) return 5;
    if (digits.length >= 6 && x.phones.some((ph) => ph.includes(digits))) return 5;
    if (x.emails.some((e) => e.includes(q))) return 4;
    if (names.some((n) => n.split(" ").includes(q) || n.includes(q))) return 3;
    if (x.companies.some((d) => d.includes(q.replace(/\s+/g, "")))) return 2;
    if (x.from_notes?.company && fold(x.from_notes.company).includes(q)) return 2;
    if (x.groups.some((gr) => fold(gr).includes(q))) return 1;
    return 0;
  };
  const people = g.people.map((x) => [score(x), x]).filter(([s]) => s > 0)
    .sort((a, b) => b[0] - a[0] || (b[1].whatsapp?.messages || 0) - (a[1].whatsapp?.messages || 0)).slice(0, limit).map(([, x]) => x);
  return { people, notes: recall(query, 5), built: g.built };
}
