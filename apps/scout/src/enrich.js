// Enrichment ("Obohatiť"): from a registry record to a company you can write to.
//   1. its website: domains guessed from the name (initlabs.sk, init-labs.sk, initlabs.com …), kept only when the site names
//      the same IČO (or, for an exact name domain, the company's name). One homepage and at most two contact pages per guess.
//   2. the website read by Scout (addresses, phones, people, the address pattern), linked to the company
//   3. an address for each konateľ: found on the site, built from the pattern, or a common-pattern guess (marked as such)
//   4. SK: employees, revenue and profit from the latest financial statement in RegisterUZ
// Polite like the crawler: robots.txt, honest User-Agent, nothing submitted anywhere.
import { promises as dns } from "node:dns";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { UA, get, normDomain, robotsRules } from "./crawl.js";
import { DATA_DIR, db, fold, now } from "./db.js";
import { linksOf, pageText } from "./extract.js";
import { guess } from "./pattern.js";
import { orgDetail } from "./prospect.js";
import { lookup } from "./registry.js";
import { company } from "./scout.js";

// ── 1. The website ─────────────────────────────────────────────────────────────────────────────────────────────────

const LEGAL_WORDS = /\b(s\.?\s?r\.?\s?o\.?|spol\.?|a\.?\s?s\.?|k\.?\s?s\.?|v\.?\s?o\.?\s?s\.?|s\.?\s?p\.?|z\.?\s?s\.?|o\.?\s?z\.?|n\.?\s?o\.?|j\.?\s?s\.?\s?a\.?|o\.?\s?p\.?\s?s\.?|druzstvo|družstvo|s ručením obmedzeným|s ručením omezeným|akciová spoločnosť|akciová společnost|v likvidácii|v likvidaci|organizačná zložka|odštepný závod|slovakia|slovensko|czech|cz|sk|eu|group|holding|company|limited|ltd|gmbh|inc)\b/gi;

/** The distinctive words of a company name: "Init Labs s. r. o." → ["init", "labs"]. */
export function nameWords(name) {
  const main = String(name ?? "").replace(/skrátená forma.*$|skrácená forma.*$/i, "").replace(/[,(].*$/, "");
  return fold(main.replace(LEGAL_WORDS, " ")).replace(/&/g, " a ").split(/[^a-z0-9]+/).filter((w) => w.length >= 2 && !/^(a|and|the|of|pre|na|v|z)$/.test(w));
}

/** Domains worth trying, best first. */
export function candidates(name, country) {
  const w = nameWords(name);
  if (!w.length) return [];
  const tlds = country === "CZ" ? ["cz", "com", "eu", "sk"] : ["sk", "com", "eu", "cz"];
  const labels = [w.join(""), w.join("-"), w.length > 2 ? w.slice(0, 2).join("") : null, w[0].length >= 5 ? w[0] : null]
    .filter((l, i, a) => l && l.length >= 3 && l.length <= 40 && a.indexOf(l) === i);
  const out = [];
  for (const l of labels) for (const t of tlds) out.push(`${l}.${t}`);
  return out.slice(0, 12);
}

const icoIn = (text, ico) => {
  const t = String(text).replace(/\s+/g, " ");
  const re = new RegExp(`(?<!\\d)${ico.slice(0, 2)}\\s?${ico.slice(2, 5)}\\s?${ico.slice(5)}(?!\\d)`);
  return re.test(t) || (ico.startsWith("00") && new RegExp(`(?<!\\d)${ico.replace(/^0+/, "")}(?!\\d)`).test(t) && /I[ČC]/.test(t));
};

async function resolves(domain) {
  try { await dns.resolve4(domain); return true; } catch {}
  try { await dns.resolveMx(domain); return true; } catch { return false; }
}

/** Does this domain belong to the company? "ico" when its pages name the IČO, "name" when an exact-name domain shows the name. */
export async function verify(domain, org) {
  if (!(await resolves(domain))) return null;
  let rules = [];
  try { const r = await get(`https://${domain}/robots.txt`, 6000); if (r.status === 200) rules = robotsRules(r.body); } catch {}
  if (rules.some((x) => x === "/" || x === "/*")) return null;
  let home;
  try { home = await get(`https://${domain}/`, 10_000); } catch { try { home = await get(`http://${domain}/`, 10_000); } catch { return null; } }
  if (home.status !== 200 || !home.body) return null;
  // a redirect to a subdomain (portal.firma.com) still means firma.com; to another domain, that one (its last two labels)
  const host = normDomain(new URL(home.url).hostname);
  const final = host === domain || host.endsWith("." + domain) ? domain : host.split(".").slice(-2).join(".");
  const text = pageText(home.body);
  if (icoIn(text, org.ico)) return { domain: final, how: "ico" };
  // the IČO lives in the imprint, contact or GDPR page
  const pages = linksOf(home.body, home.url).filter((l) => normDomain(new URL(l.url).hostname) === host && /kontakt|contact|impressum|imprint|o-nas|about|gdpr|ochrana|podmienky|obchodne|vop/i.test(l.url + " " + l.text))
    .map((l) => l.url).filter((u, i, a) => a.indexOf(u) === i).slice(0, 2);
  for (const u of pages) {
    await new Promise((r) => setTimeout(r, 800));
    try { const p = await get(u, 10_000); if (p.status === 200 && icoIn(pageText(p.body), org.ico)) return { domain: final, how: "ico" }; } catch {}
  }
  const words = nameWords(org.name);
  const label = final.split(".")[0].replace(/-/g, "");
  if (words.length && label === words.join("") && words.every((w) => fold(text).includes(w))) return { domain: final, how: "name" };
  return null;
}

export async function findDomain(org, { log = () => {} } = {}) {
  const tried = [];
  for (const c of candidates(org.name, org.country)) {
    tried.push(c);
    const v = await verify(c, org).catch(() => null);
    if (v) { log(`  ${org.name}: ${v.domain} (${v.how === "ico" ? "IČO na webe" : "názov"})`); return { ...v, tried }; }
  }
  return { domain: null, tried };
}

// ── 4. SK finances from RegisterUZ ───────────────────────────────────────────────────────────────────────────────

const RUZ = "https://www.registeruz.sk/cruz-public/api";
async function ruz(path) {
  const r = await fetch(`${RUZ}/${path}`, { headers: { "user-agent": UA, accept: "application/json" }, signal: AbortSignal.timeout(20_000) });
  if (!r.ok) throw new Error(`RegisterUZ ${r.status}`);
  return r.json();
}
async function template(id) {
  const dir = join(DATA_DIR, "templates");
  const f = join(dir, `${id}.json`);
  if (existsSync(f)) return JSON.parse(readFileSync(f, "utf8"));
  const t = await ruz(`sablona?id=${id}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(f, JSON.stringify(t));
  return t;
}
const num = (v) => (v == null || v === "" ? null : Math.round(Number(String(v).replace(/\s/g, "").replace(",", "."))));

/** Revenue ("Čistý obrat") and profit after tax from the latest regular financial statement, in EUR. */
export function readStatement(tpl, vykaz) {
  const ti = tpl.tabulky.findIndex((t) => /ziskov a str[aá]t/i.test(t.nazov?.sk ?? ""));
  if (ti < 0) return null;
  const rows = tpl.tabulky[ti].riadky;
  const data = vykaz.obsah?.tabulky?.[ti]?.data ?? [];
  const cols = rows.length ? Math.floor(data.length / rows.length) : 0;
  if (!cols) return null;
  const at = (re) => { const i = rows.findIndex((r) => re.test(r.text?.sk ?? "")); return i < 0 ? [null, null] : [num(data[i * cols]), num(data[i * cols + 1])]; };
  let [rev, revPrev] = at(/^Čistý obrat/i);
  if (rev == null) [rev, revPrev] = at(/^Tržby|^Výnosy z hospodárskej činnosti spolu/i);
  const [profit] = at(/po zdanení/i);
  return rev == null && profit == null ? null : { revenue: rev, revenuePrev: revPrev, profit };
}

export async function skFinances(ico) {
  const ids = await ruz(`uctovne-jednotky?zmenene-od=2000-01-01&ico=${ico}`);
  if (!ids.id?.length) return null;
  const unit = await ruz(`uctovna-jednotka?id=${ids.id.at(-1)}`);
  // the newest statements have the highest ids: look at the last few and take the latest regular one
  const zs = [];
  for (const id of [...(unit.idUctovnychZavierok ?? [])].sort((a, b) => b - a).slice(0, 3)) zs.push(await ruz(`uctovna-zavierka?id=${id}`));
  const z = zs.filter((x) => x.typ === "Riadna" && x.idUctovnychVykazov?.length).sort((a, b) => String(b.obdobieDo).localeCompare(String(a.obdobieDo)))[0];
  const size = await lookup(ico, { country: "SK", dir: DATA_DIR }).catch(() => null);
  if (!z) return { size };
  for (const vid of z.idUctovnychVykazov) {
    const v = await ruz(`uctovny-vykaz?id=${vid}`);
    if (v.pristupnostDat && v.pristupnostDat !== "Verejné") continue;
    const fin = readStatement(await template(v.idSablony), v);
    if (fin) return { ...fin, year: String(z.obdobieDo).slice(0, 4), size };
  }
  return { size };
}

// ── The whole enrichment of one company ──────────────────────────────────────────────────────────────────────────

/** Enriches one company (SK:12345678); returns what was found. Skips what is already known unless `fresh`. */
export async function enrichOrg(id, { fresh = false, log = () => {} } = {}) {
  const o = orgDetail(id);
  const d = db();
  const row = d.prepare("SELECT * FROM orgs WHERE country=? AND ico=?").get(o.country, o.ico);
  const out = { id: o.id, name: o.name, domain: o.sites[0]?.domain ?? null, how: o.sites.length ? "known" : null, emails: 0, people: 0, peopleWithEmail: 0 };
  out.people = d.prepare("SELECT count(*) FROM people WHERE org_id=?").pluck().get(row.id);
  if (o.dissolved) { out.note = "zaniknutá"; return mark(row.id, out); }

  // SK finances and size (RegisterUZ)
  if (o.country === "SK" && (fresh || row.revenue == null)) {
    try {
      const f = await skFinances(o.ico);
      if (f?.size?.employees) d.prepare("UPDATE orgs SET employees=?, size=? WHERE id=?").run(f.size.employees, f.size.size, row.id);
      if (f?.revenue != null || f?.profit != null) {
        d.prepare("UPDATE orgs SET revenue=?, revenue_prev=?, profit=?, fin_year=? WHERE id=?").run(f.revenue, f.revenuePrev ?? null, f.profit ?? null, f.year, row.id);
        out.revenue = f.revenue; out.profit = f.profit; out.finYear = f.year;
      }
    } catch (e) { out.finError = e.message; }
  }

  // the website
  if (!out.domain) {
    const f = await findDomain(o, { log });
    out.tried = f.tried.length;
    if (f.domain) { out.domain = f.domain; out.how = f.how; }
  }
  if (!out.domain) { out.note = `web sa nenašiel (${out.tried ?? 0} pokusov)`; return mark(row.id, out); }
  const c = await company(out.domain, { org: o.id, fresh });
  out.emails = c.emails.filter((e) => e.own).length;
  out.phones = c.phones.length;

  // an address for each konateľ (registry people) at the company's domain
  const site = { emails: c.emails, pattern: c.pattern ? { pattern: c.pattern, examples: c.patternExamples } : null, mx: c.mx };
  const people = d.prepare("SELECT * FROM people WHERE org_id=?").all(row.id);
  for (const p of people) {
    if (p.email && p.confidence === "found") { out.peopleWithEmail++; continue; }
    const g = guess(p.name, out.domain, site);
    if (!g) continue;
    d.prepare("UPDATE people SET domain=?, email=?, confidence=?, pattern=?, alternatives=?, updated_at=?, f_text=? WHERE id=?")
      .run(out.domain, g.email, g.confidence, g.pattern, g.alternatives ? JSON.stringify(g.alternatives) : null, now(),
        fold([p.name, p.role, p.company, out.domain].filter(Boolean).join(" | ")), p.id);
    out.peopleWithEmail++;
  }
  return mark(row.id, out);
}

function mark(orgId, out) {
  db().prepare("UPDATE orgs SET enriched_at=?, enrich_note=? WHERE id=?").run(now(), out.note ?? (out.domain ? `web ${out.domain}` : null), orgId);
  return out;
}

/** Many companies, a few at a time; `onResult` gets each one as it finishes (the CLI prints them as lines for the app). */
export async function enrichMany(ids, { concurrency = 4, fresh = false, onResult = () => {}, log = () => {} } = {}) {
  const queue = [...ids];
  const results = [];
  async function worker() {
    while (queue.length) {
      const id = queue.shift();
      let r;
      try { r = await enrichOrg(id, { fresh, log }); } catch (e) { r = { id, error: e.message }; }
      results.push(r);
      onResult(r, results.length, ids.length);
    }
  }
  await Promise.all(Array.from({ length: Math.min(concurrency, ids.length) }, worker));
  return {
    done: results.length, withWeb: results.filter((r) => r.domain).length, withRevenue: results.filter((r) => r.revenue != null).length,
    peopleWithEmail: results.reduce((n, r) => n + (r.peopleWithEmail ?? 0), 0), errors: results.filter((r) => r.error).length,
  };
}
