// search_everywhere: one question, asked of files, notes, people and every connected source, in parallel.
import { whereIs } from "./find.js";
import { fold, recall } from "./notes.js";
import { p } from "./paths.js";
import { callTool, resultText } from "./pool.js";
import { config, readJSON } from "./store.js";
import * as wa from "./whatsapp.js";
import * as beeper from "./beeper.js";
import { semanticSearch } from "./semantic.js";
import { addCourier } from "./mailmerge.js";
import { courierSearch } from "./courier.js";
import { isOff, serverId } from "./map.js";
import { who } from "./people.js";
import * as market from "./market.js";
import { status } from "./ui.js";

const json = (t) => { try { return JSON.parse(t); } catch { return null; } };
const daktela = (endpoint) => ({
  server: "daktela-main-write", tool: "daktela_read", args: (q) => ({ endpoint, query: { q, take: "5" } }),
  pick: (t) => (json(t)?.result?.data || []).map((r) => ({ title: r.title, name: r.name, email: r.email, account: r.account?.title })),
});

/** Built-in sources; brain.config.json "sources" can add or override entries with { server, tool, args: {...,"query":"$q"} }.
 *  A source with run(q) instead of server/tool asks in its own way. */
export const SOURCES = {
  "daktela accounts": daktela("accounts"),
  "daktela contacts": daktela("contacts"),
  selleriz: {
    server: "selleriz", tool: "selleriz_list_records", args: (q) => ({ table: "meetings", search: q }),
    pick: (t) => (json(t)?.items || []).slice(0, 5).map((m) => Object.fromEntries(Object.entries(m).filter(([k]) => /name|company|lead|date|status|outcome|time/i.test(k)).slice(0, 6))),
  },
  linkedin: {
    server: "linkedin", tool: "linkedin_search_connections", args: (q) => ({ query: q, limit: 5 }),
    pick: (t) => { const j = json(t); return j ? (j.items || j.connections || j.results || j).slice?.(0, 5) ?? j : t.slice(0, 1500); },
  },
  email: {
    server: "thunderbird-mail", tool: "searchMessages", args: (q) => ({ query: q, maxResults: 8 }),
    pick: (t) => { const j = json(t); return Array.isArray(j) ? j.slice(0, 8).map((m) => ({ client: "thunderbird", subject: m.subject, from: m.author || m.from, date: m.date,
                                                                                       folder: m.folderPath || m.folder, message_id: m.id })) : t.slice(0, 2000); },
  },
  // Courier (the user's own mail app): its local cache of every mailbox; merged into "email" afterwards, so a mail shows once
  "email courier": { label: "Courier", run: (q) => courierSearch(q, 10).then((mails) => ({ mails })) },
  // Alpaca prices for tickers in the question, and mentions in MarketBar's briefs
  market: { label: "Trhy", run: (q) => market.search(q) },
};

function custom() {
  return Object.fromEntries(Object.entries(config().sources || {}).map(([name, s]) => [name, {
    server: s.server, tool: s.tool,
    args: (q) => JSON.parse(JSON.stringify(s.args || { query: "$q" }).replaceAll("$q", q.replace(/"/g, ""))),
    pick: (t) => json(t) ?? t.slice(0, 2000),
  }]));
}

export async function searchEverywhere(query, only) {
  const sources = { ...SOURCES, ...custom() };
  // sources switched off in the Brain map stay out (Courier is its server, the rest go through `call`)
  const PART = { email: serverId("thunderbird-mail"), "email courier": serverId("courier"), market: "trading" };
  const offSrc = (n) => isOff(PART[n] || serverId(sources[n].server || n));
  const names = Object.keys(sources).filter((n) => (!only?.length || only.some((o) => n.includes(o))) && !offSrc(n));
  const people = readJSON(p("people.json"), {});
  const q = fold(query);
  status(`Pýtam sa ${names.length + 5} zdrojov naraz: súbory, poznámky, význam, WhatsApp, Messenger, ${names.join(", ")}`);
  const out = {
    files: null, notes: recall(query, 5),
    people: Object.values(people).filter((x) => fold(`${x.name} ${x.email} ${x.last_subject}`).includes(q)).slice(0, 8),
    sources: {},
  };
  await Promise.all([
    whereIs(query, 8).then((r) => { out.files = r; }),
    semanticSearch({ query, limit: 8 }).then((r) => { out.by_meaning = r; }).catch((e) => { out.by_meaning = { unavailable: e.message.slice(0, 120) }; }),
    Promise.resolve().then(() => { out.who = who(query, 3).people; }),
    !isOff("whatsapp") && (!only?.length || only.some((o) => "whatsapp".includes(o)))
      ? wa.search({ query, limit: 10 }).then((r) => { out.sources.whatsapp = r; }).catch((e) => { out.sources.whatsapp = { unavailable: e.message }; })
      : null,
    beeper.connected() && !isOff("messenger") && (!only?.length || only.some((o) => "messenger".includes(o)))
      ? beeper.search({ query, limit: 10 }).then((r) => { out.sources.messenger = r; }).catch((e) => { out.sources.messenger = { unavailable: e.message }; })
      : null,
    ...names.map(async (n) => {
      const s = sources[n];
      try {
        if (s.run) { out.sources[n] = await s.run(query); status(`${s.label || n}: ${out.sources[n].mails?.length ?? out.sources[n].briefs?.length ?? out.sources[n].length ?? 0} nájdených`); return; }
        const r = await callTool(s.server, s.tool, s.args(query), 25000);
        const t = resultText(r);
        out.sources[n] = r.isError ? { error: t.slice(0, 300) } : s.pick(t);
        status(`${n}: ${r.isError ? "chyba" : Array.isArray(out.sources[n]) ? `${out.sources[n].length} nájdených` : "hotovo"}`);
      } catch (e) {
        out.sources[n] = { unavailable: String(e.message || e).slice(0, 200) };
        status(`${n}: nedostupné`);
      }
    }),
  ]);
  mergeEmail(out.sources);
  return out;
}

/** Courier's hits and the old Thunderbird history as one "email" list; a client that failed keeps its error under its own name. */
function mergeEmail(src) {
  const tb = src.email, co = src["email courier"];
  if (!tb && !co) return;
  const tbOk = Array.isArray(tb), coOk = Array.isArray(co?.mails);
  if (!tbOk && !coOk) return;
  delete src["email courier"];
  src.email = addCourier(tbOk ? tb : [], coOk ? co.mails : []);
  if (co && !coOk) src["email courier"] = co;
  if (tb && !tbOk) src["email thunderbird"] = tb;
}
