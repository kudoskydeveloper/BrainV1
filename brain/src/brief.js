// Morning brief, built straight from the data (no model): today's calendar, mail from Courier (unread from people, tickets,
// invitations, invoices, outbox), Todoist due today and overdue (both accounts), meeting notes new since
// the last brief, WhatsApp chats whose last message is from someone else (likely waiting for your reply), and markets (Alpaca paper
// account and watchlist through market-alerts, link to MarketBar's latest brief; see market.js), and Financie (late and due
// recurring items; finance.js).
import fs from "node:fs";
import path from "node:path";
import * as calendar from "./calendar.js";
import * as celebrations from "./celebrations.js";
import * as market from "./market.js";
import { KUDOSKY_MEETINGS } from "./fathom.js";
import { p } from "./paths.js";
import { callTool, resultText } from "./pool.js";
import { readJSON, writeJSON } from "./store.js";
import * as wa from "./whatsapp.js";
import * as beeper from "./beeper.js";
import * as courier from "./courier.js";
import * as finance from "./finance.js";
import { status } from "./ui.js";

const STATE = p("brief.json");   // { last_at }
const today = () => new Date().toLocaleDateString("sv-SE");   // YYYY-MM-DD, local time
const ACCOUNTS = [{ server: "todoist", label: "Kudosky" }, { server: "todoist-10t", label: "10T" }];

async function accountTasks({ server, label }) {
  const r = await callTool(server, "find-tasks-by-date", { startDate: "today", overdueOption: "include-overdue", daysCount: 1, limit: 60 });
  const j = JSON.parse(resultText(r).split("\n")[0]);
  return (j.tasks || []).map((t) => ({ content: t.content, due: (t.dueDate || t.due?.date || "").slice(0, 10), priority: t.priority, account: label }));
}

async function tasks() {
  const got = await Promise.all(ACCOUNTS.map((a) => accountTasks(a).then((list) => ({ list }), (e) => ({ error: `${a.label}: ${e.message}` }))));
  const list = got.flatMap((g) => g.list || []);
  const errors = got.filter((g) => g.error).map((g) => g.error);
  if (errors.length === ACCOUNTS.length) throw new Error(errors.join("; "));
  const d = today();
  const order = (a, b) => String(a.priority).localeCompare(String(b.priority)) || a.due.localeCompare(b.due);
  return { overdue: list.filter((t) => t.due && t.due < d).sort(order), today: list.filter((t) => !t.due || t.due >= d).sort(order), errors };
}

function newMeetings(since) {
  let files;
  try { files = fs.readdirSync(KUDOSKY_MEETINGS); } catch { return []; }   // Drive not mounted or not permitted
  return files.filter((f) => f.endsWith(".md"))
    .map((f) => ({ f, t: fs.statSync(path.join(KUDOSKY_MEETINGS, f)).birthtimeMs }))
    .filter((x) => x.t > since).sort((a, b) => b.t - a.t)
    .map((x) => ({ title: x.f.replace(/\.md$/, ""), path: path.join(KUDOSKY_MEETINGS, x.f) }));
}

export async function morningBrief({ mark = true } = {}) {
  const state = readJSON(STATE, {});
  const since = state.last_at ? Date.parse(state.last_at) : Date.now() - 86400000;
  const [cal, t, waiting, party, mkt, fb, mail, money] = await Promise.all([
    calendar.events({ days: 1 }).catch((e) => ({ error: e.message })),
    tasks().catch((e) => ({ error: e.message })),
    wa.awaitingReply({ hours: 48, limit: 8 }).catch((e) => ({ error: e.message })),
    celebrations.upcoming({ days: 2 }).catch((e) => ({ error: e.message })),
    market.briefSection(),
    beeper.connected() ? beeper.awaitingReply({ hours: 48, limit: 8 }).catch(() => []) : [],   // Beeper off: just leave Messenger out
    courier.briefSection().catch((e) => ({ lines: [`_Pošta (Courier) nedostupná: ${String(e.message || e).slice(0, 80)}_`, ""], counts: {} })),
    finance.briefSection(),
  ]);
  status(`Kalendár: ${cal.events?.length ?? "nedostupný"} · Todoist: ${t.error ? "nedostupný" : t.overdue.length + t.today.length} · WhatsApp: ${Array.isArray(waiting) ? waiting.length : "nedostupný"} · Trhy: ${mkt.error ? "nedostupné" : "ok"}`);
  const meetings = newMeetings(since);
  const pri = (x) => ({ p1: "🔴 ", p2: "🟠 ", p3: "🔵 " }[x] || "");
  const acc = (x) => `\`${x.account}\` `;
  const L = [`**Ranný prehľad, ${new Date().toLocaleDateString("sk-SK", { weekday: "long", day: "numeric", month: "numeric" })}**`, ""];
  if (Array.isArray(party)) {
    const d = today(), mine = party.filter((i) => i.contacts.length);
    const now = mine.filter((i) => i.date === d), tomorrow = mine.filter((i) => i.date > d);
    const names = (i) => i.contacts.map((c) => c.name).join(", ");
    const others = party.filter((i) => i.date === d && !i.contacts.length).map((i) => i.who);
    if (now.length || tomorrow.length || others.length) {
      L.push("**Oslavy**", ...now.map((i) => `- 🎉 **${names(i)}**: ${i.kind}${i.kind === "meniny" ? ` (${i.who})` : ""} dnes`),
        ...tomorrow.map((i) => `- zajtra ${i.kind}: ${names(i)}`),
        ...(others.length ? [`- dnes ${others.join(", ")} (nie je v kontaktoch)`] : []), "");
    }
    if (mark && now.length) await celebrations.remindToday().catch(() => {});   // one "Napísať …" task per celebration, in Reminders
  }
  if (cal.error) L.push(`_Kalendár nedostupný: ${cal.error.slice(0, 80)}_`, "");
  else if (cal.events.length) {
    const ev = cal.events.filter((e) => !/\(meniny\)$/.test(e.title));
    const allDay = ev.filter((e) => e.all_day).map((e) => e.title);
    L.push(`**Kalendár (${ev.length})**`, ...(allDay.length ? [`- celý deň: ${allDay.join(", ")}`] : []),
      ...ev.filter((e) => !e.all_day).map((e) => `- ${e.start.slice(11, 16)}–${e.end.slice(11, 16)} ${e.title.trim()} _(${e.calendar})_${e.location ? ` · ${e.location.split("\n")[0].slice(0, 50)}` : ""}`), "");
  }
  if (t.error) L.push(`_Todoist nedostupný: ${t.error.slice(0, 80)}_`);
  else {
    for (const e of t.errors) L.push(`_Todoist nedostupný: ${e.slice(0, 80)}_`);
    if (t.overdue.length) L.push(`**Po termíne (${t.overdue.length})**`, ...t.overdue.map((x) => `- ${acc(x)}${pri(x.priority)}${x.content} _(${x.due})_`), "");
    L.push(t.today.length ? `**Dnes (${t.today.length})**` : "**Dnes:** nič naplánované", ...t.today.map((x) => `- ${acc(x)}${pri(x.priority)}${x.content}`), "");
  }
  L.push(...mail.lines);
  L.push(...money.lines);
  if (meetings.length) L.push(`**Nové meetingy (${meetings.length})**`, ...meetings.map((m) => `- [${m.title}](file://${encodeURI(m.path)})`), "");
  if (waiting.error) L.push(`_WhatsApp nedostupný: ${waiting.error.slice(0, 80)}_`);
  else if (waiting.length) L.push(`**Čaká na tvoju odpoveď (WhatsApp)**`, ...waiting.map((w) => `- **${w.chat}**${w.group ? " (skupina)" : ""}: ${w.sender && w.group ? w.sender + ": " : ""}${w.text} _(${w.ago})_`), "");
  if (fb.length) L.push(`**Čaká na tvoju odpoveď (Messenger)**`, ...fb.map((w) => `- **${w.chat}**${w.group ? " (skupina)" : ""}: ${w.sender && w.group ? w.sender + ": " : ""}${w.text} _(${w.ago})_`), "");
  L.push(...(L.at(-1) ? [""] : []), ...mkt.lines);
  const counts = { celebrations: Array.isArray(party) ? party.filter((i) => i.date === today() && i.contacts.length).length : 0, events: cal.events?.length || 0, overdue: t.overdue?.length || 0, today: t.today?.length || 0, meetings: meetings.length, waiting: (Array.isArray(waiting) ? waiting.length : 0) + fb.length, movers: mkt.movers, unprotected: mkt.unprotected || 0, ...mail.counts, ...money.counts };
  if (mark) writeJSON(STATE, { last_at: new Date().toISOString(), counts });
  return { markdown: L.join("\n").trim(), counts };
}
