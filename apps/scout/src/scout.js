// Scout's operations, shared by the MCP server, the CLI and the app: look a company up, find a person's address, the
// "nekontaktovať" list and deleting on request, search and lists. Everything kept has its source (URL, date) for GDPR.
// Data: SQLite (db.js); the output shapes are the same as when it was one JSON file, so the app, Brain and Courier don't change.
import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { crawl, normDomain } from "./crawl.js";
import { DATA_DIR, blockedList, db, fold, getPerson, isBlockedEmail, j, now, orgById, orgOut, personOut, pj, savePerson, upsertOrg, writeBlockedJson } from "./db.js";
import { isGeneric } from "./extract.js";
import { guess, hasMx, learn, ownerOf } from "./pattern.js";
import { lookup, pickIco } from "./registry.js";

export { DATA_DIR };
const AUDIT = join(DATA_DIR, "audit.log");
const FRESH_DAYS = 30;   // a company's website is read again after a month

export function audit(e) {
  try { mkdirSync(DATA_DIR, { recursive: true }); appendFileSync(AUDIT, JSON.stringify({ at: now(), ...e }) + "\n"); } catch {}
}

const blockedMark = (email) => (email && isBlockedEmail(email)) || undefined;

/** A site as the old store kept it: emails, phones, socials, pattern, MX, pages, team, org. */
function site(domain) {
  const d = db();
  const s = d.prepare("SELECT * FROM sites WHERE domain=?").get(domain);
  if (!s) return null;
  const org = orgOut(orgById(s.org_id)) ?? (s.ico ? { ico: s.ico, country: s.country } : null);
  return {
    domain, crawledAt: s.crawled_at, mx: pj(s.mx, false), pattern: pj(s.pattern), pages: pj(s.pages, []), team: pj(s.team, []), org, orgId: s.org_id,
    emails: d.prepare("SELECT * FROM emails WHERE domain=? ORDER BY own DESC, rowid").all(domain).map((e) => ({
      email: e.email, kind: e.kind, ...(e.name ? { name: e.name } : {}), how: e.how, url: e.url, context: e.context, foundAt: e.found_at, own: !!e.own })),
    phones: d.prepare("SELECT * FROM phones WHERE domain=? ORDER BY rowid").all(domain).map((p) => ({
      phone: p.phone, raw: p.raw, how: p.how, url: p.url, context: p.context, foundAt: p.found_at })),
    socials: d.prepare("SELECT * FROM socials WHERE domain=? ORDER BY rowid").all(domain).map((x) => ({ kind: x.kind, url: x.url, ...(x.text ? { text: x.text } : {}), page: x.page })),
  };
}

/** A company's website read for addresses (cached for a month; `fresh` reads it again). */
export async function company(domainInput, { fresh = false, log, org: forOrg } = {}) {
  const domain = normDomain(domainInput);
  if (!domain) throw new Error(`Not a domain: ${domainInput}`);
  const prev = site(domain);
  // "this is the website of company SK:12345678" (from the Prospector): link it, even when the site doesn't name its IČO
  const given = forOrg && String(forOrg).toUpperCase().match(/^(?:ORG:)?(SK|CZ):(\d{6,8})$/);
  const givenRow = given && db().prepare("SELECT * FROM orgs WHERE country=? AND ico=?").get(given[1], given[2].padStart(8, "0"));
  if (prev && givenRow && prev.orgId !== givenRow.id) {
    db().prepare("UPDATE sites SET org_id=?, ico=?, country=? WHERE domain=?").run(givenRow.id, givenRow.ico, givenRow.country, domain);
    db().prepare("UPDATE people SET org_id=?, company=? WHERE domain=?").run(givenRow.id, givenRow.name, domain);
    return view(site(domain));
  }
  if (prev && !fresh && Date.now() - Date.parse(prev.crawledAt) < FRESH_DAYS * 86_400_000) return view(prev);
  const [r, mx] = await Promise.all([crawl(domain, { log }), hasMx(domain)]);
  const at = now();
  // person = their name is on the site; generic = a role (info@, kariera@); other = neither (a team or service address)
  const emails = r.emails.map((e) => {
    const local = e.email.split("@")[0].replace(/[^a-z0-9]/g, "");
    const owner = isGeneric(e.email) || domain.replace(/[^a-z0-9]/g, "").includes(local) ? null : ownerOf(e.email, r.text);   // firma@gmail.com is the company
    return { email: e.email, kind: isGeneric(e.email) ? "generic" : owner ? "person" : "other", ...(owner ? { name: owner } : {}), how: e.how, url: e.url,
             context: e.context, foundAt: at, own: e.email.endsWith("@" + domain) };
  }).sort((a, b) => Number(b.own) - Number(a.own));
  const pattern = learn(emails.filter((e) => e.own).map((e) => e.email), r.text);
  // the registry: the company's own IČO from its site → name, legal form, address, industry, size
  const picked = givenRow ? { ico: givenRow.ico, country: givenRow.country } : pickIco(r.ids, domain);
  const known = picked && db().prepare("SELECT * FROM orgs WHERE ico=? AND name IS NOT NULL AND fetched_at > ?")
    .get(picked.ico, new Date(Date.now() - FRESH_DAYS * 86_400_000).toISOString());
  const org = known ? orgOut(known) : picked ? await lookup(picked.ico, { country: picked.country, dir: DATA_DIR }).catch(() => null) : null;
  const d = db();
  let added = 0;
  d.transaction(() => {
    const orgId = org ? upsertOrg(org) : null;
    d.prepare("INSERT OR REPLACE INTO sites(domain,org_id,ico,country,crawled_at,mx,pattern,pages,team) VALUES(?,?,?,?,?,?,?,?,?)")
      .run(domain, orgId, picked?.ico ?? null, org?.country ?? picked?.country ?? null, at, j(mx ? mx.slice(0, 2) : false), j(pattern), j(r.pages), j(r.people));
    for (const t of ["emails", "phones", "socials"]) d.prepare(`DELETE FROM ${t} WHERE domain=?`).run(domain);
    for (const e of emails) d.prepare("INSERT OR REPLACE INTO emails VALUES(?,?,?,?,?,?,?,?,?)")
      .run(domain, e.email, e.kind, e.name ?? null, e.how, e.url, e.context, at, e.own ? 1 : 0);
    for (const p of r.phones) d.prepare("INSERT OR REPLACE INTO phones VALUES(?,?,?,?,?,?,?)").run(domain, p.phone, p.raw, p.how, p.url, p.context, at);
    for (const x of r.socials) d.prepare("INSERT OR REPLACE INTO socials VALUES(?,?,?,?,?)").run(domain, x.kind, x.url, x.page, x.text ?? null);
    added = upsertTeam(site(domain), at);
  })();
  const c = site(domain);
  audit({ event: "company", domain, pages: r.pages.length, emails: emails.length, phones: c.phones.length, people: added, ico: org?.ico ?? picked?.ico ?? null, pattern: pattern?.pattern ?? null });
  return view(c);
}

export const personId = (name, domain) => `${fold(name).replace(/[^a-z]+/g, "-").replace(/^-|-$/g, "")}@${domain}`;

/** People named with a role on the company's site go into the people database, with an address when one is known. */
function upsertTeam(c, at) {
  const d = db();
  let n = 0;
  // people who were only on the site and are gone from it now (left the company, or a misread) are dropped, unless in a list
  const keep = new Set((c.team ?? []).map((p) => personId(p.name, c.domain)));
  for (const id of d.prepare("SELECT id FROM people WHERE domain=? AND from_site=1 AND looked_up=0 AND id NOT IN (SELECT member FROM list_members)").pluck().all(c.domain)) {
    if (!keep.has(id)) d.prepare("DELETE FROM people WHERE id=?").run(id);
  }
  for (const p of c.team ?? []) {
    const id = personId(p.name, c.domain);
    const own = c.emails.find((e) => e.name && fold(e.name) === fold(p.name));
    const g = own ? { email: own.email, confidence: "found" } : c.pattern ? guess(p.name, c.domain, c) : null;
    const phone = (c.phones ?? []).find((x) => x.context && fold(x.context).includes(fold(p.name.split(" ").pop())));
    const prev = getPerson(id) ?? {};
    savePerson({
      ...prev, id, name: p.name, title: p.title ?? prev.title, domain: c.domain, orgId: c.orgId, company: c.org?.name ?? prev.company, role: p.role, seniority: p.seniority,
      ...(g && (!prev.email || prev.confidence !== "found") ? { email: g.email, confidence: g.confidence, pattern: g.pattern, alternatives: g.alternatives } : {}),
      ...(phone ? { phone: phone.phone } : {}),
      sources: [...new Set([...(prev.sources ?? []), p.url])], fromSite: true, at: prev.at ?? at, updatedAt: at,
    });
    if (!prev.at) n++;
  }
  return n;
}

function view(c) {
  return {
    domain: c.domain, crawledAt: c.crawledAt, mx: !!c.mx, pattern: c.pattern?.pattern ?? null, patternExamples: c.pattern?.examples ?? [],
    org: c.org ?? null,
    pagesRead: c.pages.filter((p) => p.status).length, skippedByRobots: c.pages.filter((p) => p.skipped).length,
    emails: c.emails.map((e) => ({ ...e, blocked: blockedMark(e.email) })),
    phones: c.phones, socials: c.socials,
    people: db().prepare("SELECT * FROM people WHERE domain=? ORDER BY at").all(c.domain).map(personOut).map((p) => ({ ...p, blocked: blockedMark(p.email) })),
  };
}

/** A person's address at a company: found on the web, built from the learned pattern, or a common-pattern guess. */
export async function person({ name, domain: domainInput, fresh = false }) {
  const domain = normDomain(domainInput);
  if (!domain) throw new Error("Give the company's domain (e.g. firma.sk).");
  await company(domain, { fresh });
  const c = site(domain);
  const g = guess(name, domain, c);
  if (!g) return { name, domain, email: null, why: !c.mx ? "The domain takes no mail (no MX)." : "Name needs a first and a last name." };
  const id = personId(name, domain);
  const at = now();
  const prev = getPerson(id) ?? {};
  savePerson({ ...prev, id, name, domain, orgId: c.orgId, company: c.org?.name ?? prev.company, ...(prev.confidence === "found" ? {} : g), lookedUp: true, at: prev.at ?? at, updatedAt: at });
  audit({ event: "person", name, domain, email: g.email, confidence: g.confidence });
  return { name, domain, ...g, blocked: blockedMark(g.email), generic: c.emails.filter((e) => e.kind === "generic" && e.own).map((e) => e.email) };
}

/** Nekontaktovať: an address or a whole domain. */
export function block(target, { undo = false } = {}) {
  const t = String(target).trim().toLowerCase().replace(/^https?:\/\/(www\.)?/, "").replace(/\/.*$/, "");
  if (undo) db().prepare("DELETE FROM blocked WHERE target=?").run(t);
  else db().prepare("INSERT OR IGNORE INTO blocked VALUES(?,?)").run(t, now());
  writeBlockedJson();
  audit({ event: undo ? "unblock" : "block", target: t });
  return { blocked: blockedList() };
}

/** Delete on request (GDPR): every trace of an address or a domain, except that it stays on the "nekontaktovať" list. */
export function forget(target) {
  const t = String(target).trim().toLowerCase();
  const d = db();
  let n = 0;
  d.transaction(() => {
    const ids = d.prepare("SELECT id FROM people WHERE email=? OR domain=?").pluck().all(t, t);
    for (const id of ids) d.prepare("DELETE FROM list_members WHERE member=?").run(id);
    n += d.prepare("DELETE FROM people WHERE email=? OR domain=?").run(t, t).changes;
    n += d.prepare("DELETE FROM emails WHERE email=? OR domain=?").run(t, t).changes;
    n += d.prepare("DELETE FROM phones WHERE domain=?").run(t).changes;
    d.prepare("DELETE FROM socials WHERE domain=?").run(t);
    n += d.prepare("DELETE FROM sites WHERE domain=?").run(t).changes;
    d.prepare("DELETE FROM list_members WHERE member=?").run(t);
    d.prepare("INSERT OR IGNORE INTO blocked VALUES(?,?)").run(t, now());
  })();
  writeBlockedJson();
  audit({ event: "forget", target: t, removed: n });
  return { removed: n, nowBlocked: t };
}

const counts = (domain) => {
  const d = db();
  return { emails: d.prepare("SELECT count(*) FROM emails WHERE domain=?").pluck().get(domain), phones: d.prepare("SELECT count(*) FROM phones WHERE domain=?").pluck().get(domain),
    people: d.prepare("SELECT count(*) FROM people WHERE domain=?").pluck().get(domain) };
};

export function overview() {
  const d = db();
  return {
    companies: d.prepare("SELECT s.*, o.name, o.industry, o.size FROM sites s LEFT JOIN orgs o ON o.id=s.org_id ORDER BY s.crawled_at DESC").all().map((s) => ({
      domain: s.domain, name: s.name ?? null, industry: s.industry ?? null, size: s.size ?? null, crawledAt: s.crawled_at, mx: !!pj(s.mx, false),
      pattern: pj(s.pattern)?.pattern ?? null, ...counts(s.domain) })),
    people: d.prepare("SELECT * FROM people ORDER BY at DESC LIMIT 500").all().map(personOut),
    blocked: blockedList(),
    lists: lists({ action: "all" }),
    totals: { orgs: d.prepare("SELECT count(*) FROM orgs").pluck().get(), sites: d.prepare("SELECT count(*) FROM sites").pluck().get(),
      people: d.prepare("SELECT count(*) FROM people").pluck().get() },
  };
}

// ── Search over what Scout knows (Apollo-style filters, in SQL) ──────────────────────────────────────────────────────

function where(f, alias) {
  const w = [], a = [];
  const like = (col, v) => { w.push(`${col} LIKE ?`); a.push(`%${fold(v)}%`); };
  if (f.q) like(`${alias}.f_text`, f.q);
  if (f.industry) like("o.f_industry", f.industry);
  if (f.region) like("o.f_place", f.region);
  if (f.size?.length) { w.push(`o.size IN (${f.size.map(() => "?").join(",")})`); a.push(...f.size); }
  if (f.country) { w.push("o.country = ?"); a.push(f.country); }
  if (!f.includeDissolved) w.push("(o.dissolved IS NULL OR o.id IS NULL)");   // companies that no longer exist only on request
  if (f.nace) { w.push("o.nace LIKE ?"); a.push(`${String(f.nace).replace(/\D/g, "")}%`); }
  return { w, a };
}
const ORGS = "orgs";

/** People in the database, filtered: text (name, role, company), role words, seniority, company/industry/size/region, has an address. */
export function searchPeople({ q, role, seniority, domain, industry, nace, size, region, country, emailOnly, origin, includeDissolved, list, limit = 100 } = {}) {
  const { w, a } = where({ q, industry, nace, size, region, country, includeDissolved }, "p");
  if (origin) { w.push("p.origin = ?"); a.push(origin); }
  if (role) { w.push("p.f_text LIKE ?"); a.push(`%${fold(role)}%`); }
  if (seniority?.length) { w.push(`p.seniority IN (${seniority.map(() => "?").join(",")})`); a.push(...seniority); }
  if (domain) { w.push("p.domain = ?"); a.push(normDomain(domain) ?? domain); }
  if (emailOnly) w.push("p.email IS NOT NULL AND p.email NOT IN (SELECT target FROM blocked) AND substr(p.email, instr(p.email,'@')+1) NOT IN (SELECT target FROM blocked)");
  if (list) { w.push("p.id IN (SELECT member FROM list_members WHERE list_key=?)"); a.push(listKey(list)); }
  const rows = db().prepare(`SELECT p.*, o.industry AS o_industry, o.size AS o_size, o.city AS o_city FROM people p LEFT JOIN ${ORGS} o ON o.id=p.org_id
    ${w.length ? "WHERE " + w.join(" AND ") : ""} ORDER BY p.updated_at DESC LIMIT ?`).all(...a, limit);
  return rows.map((r) => ({ ...personOut(r), industry: r.o_industry ?? null, size: r.o_size ?? null, city: r.o_city ?? null, blocked: blockedMark(r.email) }));
}

/** Companies in the database, filtered by text, industry, size bucket (1-9, 10-49, 50-249, 250-999, 1000+), region, country. */
export function searchCompanies({ q, industry, nace, size, region, country, list, withSite = false, includeDissolved, limit = 100 } = {}) {
  const { w, a } = where({ q, industry, nace, size, region, country, includeDissolved }, "o");
  if (list) { w.push("s.domain IN (SELECT member FROM list_members WHERE list_key=?)"); a.push(listKey(list)); }
  if (withSite || list) w.push("s.domain IS NOT NULL");
  const rows = db().prepare(`SELECT o.*, s.domain, s.crawled_at AS crawled FROM ${ORGS} o LEFT JOIN sites s ON s.org_id=o.id
    ${w.length ? "WHERE " + w.join(" AND ") : ""} ORDER BY s.crawled_at IS NULL, s.crawled_at DESC LIMIT ?`).all(...a, limit);
  // sites read but not (yet) matched to a registry record, when the search has no registry filters
  const loose = !industry && !nace && !size?.length && !region && !country
    ? db().prepare(`SELECT * FROM sites WHERE org_id IS NULL ${q ? "AND domain LIKE ?" : ""} ${list ? "AND domain IN (SELECT member FROM list_members WHERE list_key=?)" : ""} LIMIT ?`)
      .all(...[q ? `%${fold(q)}%` : null, list ? listKey(list) : null].filter((x) => x != null), limit) : [];
  return [...rows.map((r) => ({ domain: r.domain ?? null, ...orgOut(r), ...(r.domain ? counts(r.domain) : { emails: 0, phones: 0, people: 0 }), crawledAt: r.crawled ?? null })),
    ...loose.map((s) => ({ domain: s.domain, ...(s.ico ? { ico: s.ico, country: s.country } : {}), ...counts(s.domain), crawledAt: s.crawled_at }))].slice(0, limit);
}

// ── Lists: saved sets of people (by id) and companies (by domain), for sequences, Obchody or a CSV ────────────────────

export const listKey = (name) => fold(name).trim().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");

/** create · add · remove · show · delete · all. Members are person ids (meno-priezvisko@firma.sk), e-mails or domains. */
export function lists({ action = "all", name, members = [] } = {}) {
  const d = db();
  if (action === "all") return d.prepare("SELECT l.name, l.created_at AS createdAt, (SELECT count(*) FROM list_members m WHERE m.list_key=l.key) AS members FROM lists l ORDER BY l.created_at")
    .all().map((l) => ({ name: l.name, members: l.members, createdAt: l.createdAt }));
  const key = name && listKey(name);
  if (!key) throw new Error("Give the list's name.");
  const at = now();
  if (action === "delete") {
    d.transaction(() => { d.prepare("DELETE FROM list_members WHERE list_key=?").run(key); d.prepare("DELETE FROM lists WHERE key=?").run(key); })();
    audit({ event: "list-delete", list: key });
    return { deleted: name };
  }
  d.prepare("INSERT OR IGNORE INTO lists VALUES(?,?,?,NULL)").run(key, name, at);
  if (action === "add" || action === "remove") {
    // an e-mail becomes the person who has it; anything else is kept as given (a person id or a domain)
    // a company from the register is "org:SK:12345678" (given as SK:12345678 or org:SK:…)
    const ids = members.map((m) => String(m).trim()).map((m) => {
      const o = m.match(/^(?:org:)?(SK|CZ):(\d{6,8})$/i);
      if (o) return `org:${o[1].toUpperCase()}:${o[2].padStart(8, "0")}`;
      const l = m.toLowerCase();
      return d.prepare("SELECT id FROM people WHERE email=?").pluck().get(l) ?? (l.includes("@") || l.includes(".") ? l : m);
    });
    d.transaction(() => {
      for (const id of ids) {
        if (action === "add") d.prepare("INSERT OR IGNORE INTO list_members VALUES(?,?,?)").run(key, id, at);
        else d.prepare("DELETE FROM list_members WHERE list_key=? AND member=?").run(key, id);
      }
      d.prepare("UPDATE lists SET updated_at=? WHERE key=?").run(at, key);
    })();
    audit({ event: `list-${action}`, list: key, members: members.length });
  }
  return showList(key);
}

function showList(key) {
  const d = db();
  const l = d.prepare("SELECT * FROM lists WHERE key=?").get(key);
  if (!l) return { name: null, people: [], companies: [], unknown: [] };
  const members = d.prepare("SELECT member FROM list_members WHERE list_key=? ORDER BY added_at, rowid").pluck().all(key);
  const people = [], companies = [], unknown = [];
  for (const m of members) {
    const p = getPerson(m);
    if (p) { people.push({ ...p, blocked: blockedMark(p.email) }); continue; }
    const o = m.match(/^org:(SK|CZ):(\d{8})$/);
    if (o) {
      const r = d.prepare("SELECT * FROM orgs WHERE country=? AND ico=?").get(o[1], o[2]);
      if (r) {
        const dom = d.prepare("SELECT domain FROM sites WHERE org_id=? ORDER BY crawled_at DESC LIMIT 1").pluck().get(r.id);
        companies.push({ id: `${r.country}:${r.ico}`, domain: dom ?? null, ...orgOut(r), generic: dom ? d.prepare("SELECT email FROM emails WHERE domain=? AND kind='generic' AND own=1").pluck().all(dom) : [] });
        continue;
      }
    }
    const s = site(m);
    if (s) { companies.push({ domain: m, ...(s.org ?? {}), generic: s.emails.filter((e) => e.kind === "generic" && e.own).map((e) => e.email) }); continue; }
    unknown.push(m);
  }
  return { name: l.name, createdAt: l.created_at, updatedAt: l.updated_at ?? undefined, people, companies, unknown };
}

/** A list (or a search) as CSV for Courier sequences, Obchody or a spreadsheet. Blocked addresses are left out. */
export function exportCsv({ list, ...filters } = {}) {
  const rows = list ? showList(listKey(list)).people : searchPeople({ ...filters, limit: filters.limit ?? 100_000 });
  const cols = ["name", "email", "confidence", "role", "seniority", "company", "domain", "phone"];
  const q = (v) => (v == null ? "" : /[",\n;]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
  return [cols.join(","), ...rows.filter((p) => !p.blocked).map((p) => cols.map((c) => q(p[c])).join(","))].join("\n");
}
