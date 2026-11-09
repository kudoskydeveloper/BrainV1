// How Brain talks back: live status lines while a tool works ("Prechádzam WhatsApp…") and readable Markdown instead of JSON.
// status() can be called from anywhere inside a tool run (AsyncLocalStorage); it goes out as an MCP progress notification
// when the client asked for progress, and the trail is shown on top of the result either way.
import { AsyncLocalStorage } from "node:async_hooks";
import { lines as marketLines } from "./market.js";

const als = new AsyncLocalStorage();

export function run(ctx, fn) { return als.run({ steps: [], n: 0, ...ctx }, fn); }

/** Tell the user what Brain is doing now. */
export function status(msg) {
  const c = als.getStore();
  if (!c) return;
  c.steps.push(msg);
  c.send?.(msg, ++c.n);
}

export const steps = () => als.getStore()?.steps || [];

// ---- rendering --------------------------------------------------------------------------------------------------

const LABELS = { files: "Súbory", notes: "Poznámky", people: "Ľudia z e-mailov", sources: "Zdroje", by_meaning: "Podľa významu", who: "Kto je kto",
  learned: "Naučené odkazy", projects: "Projekty", bookmarks: "Záložky", whatsapp: "WhatsApp", email: "E-mail", servers: "MCP servery", last_scan: "Posledný scan" };
const label = (k) => LABELS[k] || k.replace(/_/g, " ");
const empty = (v) => v === undefined || v === null || v === "" || (Array.isArray(v) && !v.length)
  || (typeof v === "object" && !Array.isArray(v) && Object.values(v).every(empty));
const SKIP = new Set(["full"]);   // full path repeats the shown ~/ path
const TITLE = ["title", "name", "subject", "chat", "content", "topic", "summary", "path", "query"];
const short = (s, n = 300) => (s.length > n ? s.slice(0, n) + "…" : s);
const prim = (v) => v === null || ["string", "number", "boolean"].includes(typeof v);
const val = (v) => (typeof v === "boolean" ? (v ? "áno" : "nie") : String(v));
// the invite's own text, without the Google Meet / Teams join block calendars append to the end
const eventText = (n) => (n || "").replace(/-::~:~::~[\s\S]*$/, "").replace(/_{10,}[\s\S]*?(Microsoft Teams|Join the meeting|Pripojiť sa)[\s\S]*$/i, "").replace(/\n{3,}/g, "\n\n").trim();
const quote = (t) => t.split("\n").map((l) => `  > ${l}`).join("\n");
const dayName = (d) => new Date(`${d}T12:00:00`).toLocaleDateString("sk-SK", { weekday: "long", day: "numeric", month: "numeric" });

function line(o) {
  const t = TITLE.find((k) => typeof o[k] === "string" && o[k].trim());
  const rest = Object.entries(o).filter(([k, v]) => k !== t && !SKIP.has(k) && !empty(v))
    .map(([k, v]) => prim(v) ? `${label(k)}: ${short(val(v).replace(/\s+/g, " "), 200)}`
      : Array.isArray(v) && v.every(prim) ? `${label(k)}: ${v.join(", ")}` : `${label(k)}: ${short(JSON.stringify(v), 200)}`);
  return `${t ? `**${short(o[t].replace(/\s+/g, " ").trim(), 140)}**` : ""}${t && rest.length ? " · " : ""}${rest.join(" · ")}`;
}

/** Any value as Markdown: lists of records become bullet lines, objects become labelled sections. */
export function md(v, depth = 0) {
  if (v === undefined || v === null) return "_nič_";
  if (prim(v)) return val(v);
  if (Array.isArray(v)) {
    if (!v.length) return "_nič_";
    return v.map((x) => `- ${prim(x) ? val(x) : Array.isArray(x) ? x.join(", ") : line(x)}`).join("\n");
  }
  const out = [];
  for (const [k, x] of Object.entries(v)) {
    if (empty(x)) continue;
    if (prim(x) && !(typeof x === "string" && (x.includes("\n") || x.length > 200))) out.push(`**${label(k)}:** ${val(x)}`);
    else out.push(`${depth ? "####" : "###"} ${label(k)}\n${typeof x === "string" ? x : md(x, depth + 1)}`);
  }
  return out.length ? out.join(depth ? "\n" : "\n\n") : "_nič_";
}

const RENDER = {
  market_overview: (o) => ["**Trhy (Alpaca)**", ...marketLines(o, { top: 20 }), ...(o.latest_brief ? [`- MarketBar brief: ${o.latest_brief}`] : []),
    "", "_Dáta: Alpaca paper účet, IEX. Na sledovanie, nie investičná rada._"].join("\n"),
  market_briefs: (r) => Array.isArray(r) ? r.map((b) => `- ${b.date} · ${b.path}`).join("\n") || "_žiadne briefy_" : `${r.markdown}\n\n_${r.path}_`,
  calendar_events: (r) => {
    if (!r.events.length) return `Žiadne udalosti (${r.from} → ${r.to}).`;
    const L = [`**${r.count} udalostí** (${r.from} → ${r.to})`];
    let d = "";
    for (const e of r.events) {
      if (e.start.slice(0, 10) !== d) { d = e.start.slice(0, 10); L.push("", `**${dayName(d)}**`); }
      const when = e.all_day ? "celý deň" : `${e.start.slice(11, 16)}–${e.end.slice(11, 16)}`;
      const extra = [e.location && e.location.split("\n")[0].slice(0, 60), e.attendees?.length && `${e.attendees.length} účastníkov`, e.recurring && "opakuje sa"].filter(Boolean);
      L.push(`- ${when} **${e.title.trim() || "(bez názvu)"}** _(${e.calendar})_${extra.length ? ` · ${extra.join(" · ")}` : ""} \`${e.id}\``);
      // a few events: the whole description; a full day of them: a longer preview, the rest via calendar_event
      const notes = eventText(e.notes);
      if (notes) L.push(r.events.length <= 5 ? quote(notes) : quote(short(notes, 600)) + (notes.length > 600 ? `\n  _(celý popis: calendar_event \`${e.id}\`)_` : ""));
    }
    return L.join("\n");
  },
  celebrations: (items) => {
    if (!items.length) return "Nikto neoslavuje.";
    const L = []; let d = "";
    for (const i of items) {
      if (i.date !== d) { d = i.date; L.push(`${L.length ? "\n" : ""}**${dayName(d)}**`); }
      const who = i.contacts.length ? i.contacts.map((c) => `**${c.name}**${c.phone ? ` (${c.phone})` : ""}`).join(", ")
        : i.kind === "meniny" ? "_nikto z kontaktov_" : `${i.who} _(nie je v kontaktoch)_`;
      L.push(`- ${i.kind === "narodeniny" ? "🎂" : "🌼"} ${i.kind}${i.kind === "meniny" ? ` ${i.who}` : ""}${i.age ? `, ${i.age} r.` : ""}: ${who}`);
    }
    return L.join("\n");
  },
  calendar_event: (e) => {
    const L = [`## ${e.title.trim() || "(bez názvu)"}`, `${dayName(e.start.slice(0, 10))}, ${e.all_day ? "celý deň" : `${e.start.slice(11, 16)}–${e.end.slice(11, 16)}`} · _${e.calendar}_${e.recurring ? " · opakuje sa" : ""}`];
    if (e.location) L.push(`**Miesto:** ${e.location}`);
    if (e.organizer) L.push(`**Organizátor:** ${e.organizer}`);
    if (e.attendees?.length) L.push(`**Účastníci:** ${e.attendees.map((a) => a.name || a.email).join(", ")}`);
    if (e.url) L.push(`**Odkaz:** ${e.url}`);
    L.push("", eventText(e.notes) || "_bez popisu_", "", `_${e.note}_ · \`${e.id}\``);
    return L.join("\n");
  },
  calendar_free: (slots) => {
    if (!slots.length) return "Žiadny voľný čas v tomto rozsahu.";
    const L = []; let d = "";
    for (const s of slots) { if (s.date !== d) { d = s.date; L.push(`${L.length ? "\n" : ""}**${dayName(d)}**`); } L.push(`- ${s.from}–${s.to} (${s.minutes} min)`); }
    return L.join("\n");
  },
  calendar_list: (cals) => {
    const by = {};
    for (const c of cals) (by[c.account] ||= []).push(c);
    return Object.entries(by).map(([a, cs]) => `**${a}**\n${cs.map((c) => `- ${c.title}${c.writable ? "" : " _(len čítanie)_"}${c.hidden_by_default ? " _(skrytý)_" : ""}`).join("\n")}`).join("\n\n");
  },
  search_everywhere: (r) => {
    const parts = [];
    const sec = (title, v) => { if (!empty(v)) parts.push(`### ${title}\n${md(v, 1)}`); };
    sec("Súbory a projekty", r.files);
    sec("Kto je kto", r.who);
    sec("Podľa významu", Array.isArray(r.by_meaning) ? r.by_meaning.map((h) => ({ title: h.title, source: h.source, date: h.date, where: h.where, excerpt: short(h.excerpt.replace(/\s+/g, " "), 160) })) : r.by_meaning);
    sec("Poznámky v Braine", r.notes);
    sec("Ľudia z e-mailov", r.people);
    for (const [n, v] of Object.entries(r.sources || {})) sec(n[0].toUpperCase() + n.slice(1), v);
    return parts.join("\n\n") || "Nikde som nič nenašiel.";
  },
  meeting_prep: (r) => {
    const m = r.meeting, L = [`## ${m.title}`, `${dayName(m.start.slice(0, 10))}, ${m.start.slice(11, 16)}–${m.end.slice(11, 16)} · _${m.calendar}_${m.location ? ` · ${m.location.split("\n")[0].slice(0, 80)}` : ""}`];
    if (m.agenda) L.push("", eventText(m.agenda).split("\n").map((l) => `> ${l}`).join("\n"));
    for (const p of r.people) {
      L.push("", `### ${p.name || p.email}${p.email && p.name ? ` · ${p.email}` : ""}${p.company ? ` · ${p.company}` : ""}`);
      if (p.known_as) L.push(md(p.known_as, 1));
      if (!empty(p.crm)) L.push(`**Daktela CRM:** ${md(p.crm, 1)}`);
      if (!empty(p.emails)) L.push(`**E-maily**\n${md(p.emails.map((e) => ({ title: e.title, date: e.date })), 1)}`);
      if (!empty(p.whatsapp)) L.push(`**WhatsApp**\n${md(p.whatsapp, 1)}`);
      if (!p.known_as && empty(p.emails) && empty(p.whatsapp) && empty(p.crm)) L.push("_Nič o tomto človeku nemám._");
    }
    const sec = (t, v) => { if (!empty(v) && !v.unavailable) L.push("", `### ${t}`, md(v, 1)); };
    sec("Predchádzajúce meetingy", Array.isArray(r.earlier_meetings) && r.earlier_meetings.map((e) => ({ title: e.title, date: e.start.slice(0, 10), calendar: e.calendar })));
    sec("Poznámky a nahrávky", Array.isArray(r.notes_and_recordings) && r.notes_and_recordings.map((h) => ({ title: h.title, date: h.date, source: h.source, excerpt: short(h.excerpt.replace(/\s+/g, " "), 160) })));
    sec("Súvisiace e-maily", Array.isArray(r.related_emails) && r.related_emails.map((h) => ({ title: h.title, date: h.date })));
    sec("Otvorené úlohy", r.open_tasks);
    L.push("", `_id: \`${m.id}\`_`);
    return L.join("\n");
  },
  client: (r) => {
    const L = [`## ${r.client}`];
    const sec = (t, v) => { if (!empty(v) && !v.unavailable) L.push("", `### ${t}`, md(v, 1)); };
    sec("Otvorené úlohy", r.open_tasks);
    sec("Najbližšie v kalendári", Array.isArray(r.upcoming_events) && r.upcoming_events.map((e) => ({ title: e.title, when: e.start.replace("T", " ").slice(0, 16), calendar: e.calendar })));
    sec("Posledné e-maily", Array.isArray(r.latest_emails) && r.latest_emails.map((e) => ({ title: e.title, date: e.date, excerpt: short(e.excerpt.replace(/\s+/g, " "), 180) })));
    sec("Ďalšie podľa významu", Array.isArray(r.more_by_meaning) && r.more_by_meaning.map((e) => ({ title: e.title, date: e.date, source: e.source })));
    sec("WhatsApp", r.whatsapp);
    sec("Nedávne udalosti", Array.isArray(r.recent_events) && r.recent_events.map((e) => ({ title: e.title, date: e.start.slice(0, 10) })));
    sec("Ľudia", r.people);
    sec("Apple Notes", r.apple_notes);
    sec("Poznámky v Braine", r.brain_notes);
    sec("Súbory", r.files);
    return L.length > 1 ? L.join("\n") : `O „${r.client}“ som nič nenašiel.`;
  },
  reminders_list: (rs) => !rs.length ? "Nič otvorené." : rs.map((r) => `- [${r.done ? "x" : " "}] **${r.title}** _(${r.list})_${r.due ? ` · ${r.due.replace("T", " ")}` : ""}${r.priority ? " · ❗" : ""} \`${r.id}\`${r.notes ? `\n  > ${short(r.notes.replace(/\s+/g, " "), 160)}` : ""}`).join("\n"),
  shopping_list: (r) => `**Nákupný zoznam (${r.list})**\n${r.on_list.length ? r.on_list.map((i) => `- [ ] ${i.title} \`${i.id}\``).join("\n") : "_prázdny_"}\n\n**Čo zvyčajne ješ**\n${r.what_you_eat}\n\n_${r.how}_`,
  shopping_add: (r) => `**Pridané do ${r.list}:** ${r.added.join(", ") || "nič"}${r.already_there.length ? `\n_Už tam bolo:_ ${r.already_there.join(", ")}` : ""}`,
  semantic_search: (hits) => !hits.length ? "Nič podobné som nenašiel." : hits.map((h, i) =>
    `${i + 1}. **${h.title}** · ${h.source}${h.date ? ` · ${h.date}` : ""} · zhoda ${Math.round(h.score * 100)} %\n   ${h.where}\n   > ${short(h.excerpt.replace(/\s+/g, " "), 280)}`).join("\n"),
  apple_notes_read: (n) => `### ${n.name}\n_${n.folder} · ${n.modified}_ · \`${n.id}\`\n\n${n.text}\n\n_${n.note}_`,
  whatsapp_read: (r) => md(r),
};

/** The text a tool returns: what Brain did, then the result. */
export function render(name, v) {
  if (v && typeof v === "object" && v.needs_confirm)
    return [`**Čaká na tvoje potvrdenie**`, "", v.summary, "", `proposal: \`${v.proposal_id}\``, `_${v.next}_`].join("\n");
  const body = typeof v === "string" ? v : (RENDER[name] || md)(v);
  const trail = steps();
  return trail.length ? `${trail.map((s) => `› ${s}`).join("\n")}\n\n${body}` : body;
}
