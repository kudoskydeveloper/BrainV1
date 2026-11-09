// Scout's database: one SQLite file (~/.scout/scout.sqlite, WAL), built to hold every SK/CZ company and its people.
// Plain SQL (TEXT/INTEGER, JSON kept as TEXT), so it can move to Postgres/Supabase later with a straight copy.
//
//   orgs      a registered company (country + IČO): name, legal form, address, industry, size …   (registry, no website needed)
//   sites     a website Scout read: when, MX, learned address pattern, pages; linked to its org by the IČO on the site
//   emails · phones · socials   what was found on a site, each with the page it was on
//   people    a person at a company: role, seniority, address and how sure, sources
//   lists · list_members · blocked (Nekontaktovať) · meta
import Database from "better-sqlite3";
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const DATA_DIR = process.env.SCOUT_DIR ?? join(homedir(), ".scout");
export const DB_PATH = join(DATA_DIR, "scout.sqlite");
/** Courier reads the Nekontaktovať list from here before every sequence e-mail. */
export const BLOCKED_JSON = join(DATA_DIR, "blocked.json");

export const fold = (s) => String(s ?? "").normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();

const SCHEMA = `
CREATE TABLE IF NOT EXISTS orgs(
  id INTEGER PRIMARY KEY, country TEXT NOT NULL, ico TEXT NOT NULL, name TEXT, legal_form TEXT, dic TEXT, address TEXT, city TEXT,
  region TEXT, founded TEXT, dissolved TEXT, nace TEXT, industry TEXT, employees TEXT, size TEXT, source TEXT, fetched_at TEXT,
  f_text TEXT, f_industry TEXT, f_place TEXT, UNIQUE(country, ico));
CREATE INDEX IF NOT EXISTS orgs_size ON orgs(size);
CREATE INDEX IF NOT EXISTS orgs_nace ON orgs(nace);
CREATE TABLE IF NOT EXISTS sites(
  domain TEXT PRIMARY KEY, org_id INTEGER REFERENCES orgs(id), ico TEXT, country TEXT, crawled_at TEXT, mx TEXT, pattern TEXT,
  pages TEXT, team TEXT);
CREATE INDEX IF NOT EXISTS sites_org ON sites(org_id);
CREATE TABLE IF NOT EXISTS emails(
  domain TEXT NOT NULL, email TEXT NOT NULL, kind TEXT, name TEXT, how TEXT, url TEXT, context TEXT, found_at TEXT, own INTEGER,
  PRIMARY KEY(domain, email));
CREATE INDEX IF NOT EXISTS emails_email ON emails(email);
CREATE TABLE IF NOT EXISTS phones(
  domain TEXT NOT NULL, phone TEXT NOT NULL, raw TEXT, how TEXT, url TEXT, context TEXT, found_at TEXT, PRIMARY KEY(domain, phone));
CREATE TABLE IF NOT EXISTS socials(domain TEXT NOT NULL, kind TEXT, url TEXT NOT NULL, page TEXT, text TEXT, PRIMARY KEY(domain, url));
CREATE TABLE IF NOT EXISTS people(
  id TEXT PRIMARY KEY, name TEXT, title TEXT, domain TEXT, org_id INTEGER REFERENCES orgs(id), company TEXT, role TEXT, seniority TEXT,
  email TEXT, confidence TEXT, pattern TEXT, alternatives TEXT, phone TEXT, sources TEXT, from_site INTEGER DEFAULT 0,
  looked_up INTEGER DEFAULT 0, at TEXT, updated_at TEXT, f_text TEXT);
CREATE INDEX IF NOT EXISTS people_domain ON people(domain);
CREATE INDEX IF NOT EXISTS people_email ON people(email);
CREATE INDEX IF NOT EXISTS people_org ON people(org_id);
CREATE INDEX IF NOT EXISTS people_seniority ON people(seniority);
CREATE TABLE IF NOT EXISTS lists(key TEXT PRIMARY KEY, name TEXT, created_at TEXT, updated_at TEXT);
CREATE TABLE IF NOT EXISTS list_members(list_key TEXT NOT NULL, member TEXT NOT NULL, added_at TEXT, PRIMARY KEY(list_key, member));
CREATE INDEX IF NOT EXISTS list_members_member ON list_members(member);
CREATE TABLE IF NOT EXISTS blocked(target TEXT PRIMARY KEY, at TEXT);
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
`;

let handle;
/** The open database (created and migrated on first use; the old store.json is imported once). */
export function db() {
  if (handle) return handle;
  mkdirSync(DATA_DIR, { recursive: true });
  handle = new Database(DB_PATH);
  handle.pragma("journal_mode = WAL");
  handle.pragma("synchronous = NORMAL");
  handle.pragma("foreign_keys = ON");
  handle.exec(SCHEMA);
  // columns added after the first SQLite version
  const cols = new Set(handle.prepare("PRAGMA table_info(people)").all().map((c) => c.name));
  if (!cols.has("origin")) handle.exec("ALTER TABLE people ADD COLUMN origin TEXT");   // site | lookup | registry
  handle.exec("DROP INDEX IF EXISTS orgs_dissolved; CREATE INDEX IF NOT EXISTS orgs_ico ON orgs(ico); CREATE INDEX IF NOT EXISTS people_at ON people(at); CREATE INDEX IF NOT EXISTS people_updated ON people(updated_at)");
  prospectorIndexes(handle);
  importLegacy(handle);
  return handle;
}

/** What the Prospector filters on: the NACE division (first two digits), place, legal form, founding date, and a full-text
 *  index of name, industry and place (accent-insensitive, word prefixes). Built once; triggers keep it current. */
function prospectorIndexes(d) {
  const cols = new Set(d.prepare("PRAGMA table_xinfo(orgs)").all().map((c) => c.name));
  if (!cols.has("nace2")) d.exec("ALTER TABLE orgs ADD COLUMN nace2 TEXT GENERATED ALWAYS AS (substr(nace, 1, 2)) VIRTUAL");
  // finances (SK, from the financial statements in RegisterUZ, filled by enrichment) and the enrichment state
  for (const [c, t] of [["revenue", "INTEGER"], ["revenue_prev", "INTEGER"], ["profit", "INTEGER"], ["fin_year", "TEXT"], ["enriched_at", "TEXT"], ["enrich_note", "TEXT"]])
    if (!cols.has(c)) d.exec(`ALTER TABLE orgs ADD COLUMN ${c} ${t}`);
  d.exec("CREATE INDEX IF NOT EXISTS orgs_revenue ON orgs(revenue)");
  d.exec(`
    CREATE INDEX IF NOT EXISTS orgs_country_region ON orgs(country, region);
    CREATE INDEX IF NOT EXISTS orgs_nace2 ON orgs(nace2);
    CREATE INDEX IF NOT EXISTS orgs_region_nace2 ON orgs(region, nace2, dissolved);
    CREATE INDEX IF NOT EXISTS orgs_country_nace2 ON orgs(country, nace2, dissolved);
    CREATE INDEX IF NOT EXISTS orgs_founded ON orgs(founded);
    CREATE INDEX IF NOT EXISTS orgs_country_founded ON orgs(country, founded);
    CREATE INDEX IF NOT EXISTS orgs_country_name ON orgs(country, name);
    CREATE INDEX IF NOT EXISTS orgs_legal_form ON orgs(legal_form);
    CREATE INDEX IF NOT EXISTS orgs_name ON orgs(name);
    CREATE INDEX IF NOT EXISTS sites_org2 ON sites(org_id);`);
  if (!d.prepare("SELECT 1 FROM sqlite_master WHERE name='orgs_fts'").get()) {
    d.exec(`
      CREATE VIRTUAL TABLE orgs_fts USING fts5(f_text, content='orgs', content_rowid='id', tokenize='unicode61 remove_diacritics 2');
      CREATE TRIGGER orgs_fts_ai AFTER INSERT ON orgs BEGIN INSERT INTO orgs_fts(rowid, f_text) VALUES (new.id, new.f_text); END;
      CREATE TRIGGER orgs_fts_ad AFTER DELETE ON orgs BEGIN INSERT INTO orgs_fts(orgs_fts, rowid, f_text) VALUES('delete', old.id, old.f_text); END;
      CREATE TRIGGER orgs_fts_au AFTER UPDATE OF f_text ON orgs BEGIN
        INSERT INTO orgs_fts(orgs_fts, rowid, f_text) VALUES('delete', old.id, old.f_text);
        INSERT INTO orgs_fts(rowid, f_text) VALUES (new.id, new.f_text);
      END;
      INSERT INTO orgs_fts(orgs_fts) VALUES('rebuild');`);
  }
  if (!d.prepare("SELECT 1 FROM sqlite_master WHERE name='people_fts'").get()) {
    d.exec(`
      CREATE VIRTUAL TABLE people_fts USING fts5(f_text, content='people', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2');
      CREATE TRIGGER people_fts_ai AFTER INSERT ON people BEGIN INSERT INTO people_fts(rowid, f_text) VALUES (new.rowid, new.f_text); END;
      CREATE TRIGGER people_fts_ad AFTER DELETE ON people BEGIN INSERT INTO people_fts(people_fts, rowid, f_text) VALUES('delete', old.rowid, old.f_text); END;
      CREATE TRIGGER people_fts_au AFTER UPDATE OF f_text ON people BEGIN
        INSERT INTO people_fts(people_fts, rowid, f_text) VALUES('delete', old.rowid, old.f_text);
        INSERT INTO people_fts(rowid, f_text) VALUES (new.rowid, new.f_text);
      END;
      INSERT INTO people_fts(people_fts) VALUES('rebuild');`);
  }
}

/** For tests: close so the next db() opens SCOUT_DIR afresh. */
export function closeDb() { handle?.close(); handle = undefined; }

export const j = (v) => (v == null ? null : JSON.stringify(v));
export const pj = (v, d = null) => { try { return v == null ? d : JSON.parse(v); } catch { return d; } };
export const now = () => new Date().toISOString();

// ── Orgs ───────────────────────────────────────────────────────────────────────────────────────────────────────────

/** Inserts or updates a registry record ({country, ico, name, legalForm, …} as registry.js returns it); returns its id. */
export function upsertOrg(o) {
  const d = db();
  d.prepare(`INSERT INTO orgs(country,ico,name,legal_form,dic,address,city,region,founded,dissolved,nace,industry,employees,size,source,fetched_at,f_text,f_industry,f_place)
    VALUES(@country,@ico,@name,@legalForm,@dic,@address,@city,@region,@founded,@dissolved,@nace,@industry,@employees,@size,@source,@fetchedAt,@f,@fi,@fp)
    ON CONFLICT(country,ico) DO UPDATE SET name=COALESCE(excluded.name,name), legal_form=COALESCE(excluded.legal_form,legal_form),
      dic=COALESCE(excluded.dic,dic), address=COALESCE(excluded.address,address), city=COALESCE(excluded.city,city),
      region=COALESCE(excluded.region,region), founded=COALESCE(excluded.founded,founded), dissolved=excluded.dissolved,
      nace=COALESCE(excluded.nace,nace), industry=COALESCE(excluded.industry,industry), employees=COALESCE(excluded.employees,employees),
      size=COALESCE(excluded.size,size), source=COALESCE(excluded.source,source), fetched_at=excluded.fetched_at, f_text=excluded.f_text,
      f_industry=COALESCE(excluded.f_industry,f_industry), f_place=COALESCE(excluded.f_place,f_place)`)
    .run({
      country: o.country, ico: o.ico, name: o.name ?? null, legalForm: o.legalForm ?? null, dic: o.dic ?? null, address: o.address ?? null,
      city: o.city ?? null, region: o.region ?? null, founded: o.founded ?? null, dissolved: o.dissolved ?? null, nace: o.nace ?? null,
      industry: o.industry ?? null, employees: o.employees ?? null, size: o.size ?? null, source: o.source ?? null, fetchedAt: o.fetchedAt ?? now(),
      f: fold([o.name, o.industry, o.city, o.region].filter(Boolean).join(" | ")),
      fi: o.industry ? fold(o.industry) : null, fp: o.city || o.region ? fold([o.city, o.region, o.address].filter(Boolean).join(" | ")) : null,
    });
  return d.prepare("SELECT id FROM orgs WHERE country=? AND ico=?").get(o.country, o.ico).id;
}

/** The registry record in the shape the CLI, MCP and apps have always shown. */
export function orgOut(r) {
  if (!r) return null;
  return { country: r.country, ico: r.ico, name: r.name, legalForm: r.legal_form, dic: r.dic, address: r.address, city: r.city, region: r.region,
    founded: r.founded, ...(r.dissolved ? { dissolved: r.dissolved } : {}), nace: r.nace, industry: r.industry, employees: r.employees, size: r.size,
    ...(r.revenue != null ? { revenue: r.revenue, revenuePrev: r.revenue_prev ?? undefined, profit: r.profit ?? undefined, finYear: r.fin_year ?? undefined } : {}),
    ...(r.enriched_at ? { enrichedAt: r.enriched_at, enrichNote: r.enrich_note ?? undefined } : {}),
    source: r.source, fetchedAt: r.fetched_at };
}
export const orgById = (id) => (id == null ? null : db().prepare("SELECT * FROM orgs WHERE id=?").get(id));

// ── People ─────────────────────────────────────────────────────────────────────────────────────────────────────────

const PEOPLE_COLS = ["id", "name", "title", "domain", "org_id", "company", "role", "seniority", "email", "confidence", "pattern", "alternatives",
  "phone", "sources", "from_site", "looked_up", "at", "updated_at", "f_text", "origin"];

export function personOut(r) {
  if (!r) return null;
  const p = { id: r.id, name: r.name, domain: r.domain };
  for (const [k, v] of [["title", r.title], ["company", r.company], ["role", r.role], ["seniority", r.seniority], ["email", r.email],
    ["confidence", r.confidence], ["pattern", r.pattern], ["phone", r.phone]]) if (v != null) p[k] = v;
  const alt = pj(r.alternatives);
  if (alt?.length) p.alternatives = alt;
  const src = pj(r.sources, []);
  if (src.length) p.sources = src;
  if (r.from_site) p.fromSite = true;
  if (r.looked_up) p.lookedUp = true;
  if (r.origin) p.origin = r.origin;
  p.at = r.at;
  p.updatedAt = r.updated_at;
  return p;
}

/** Writes a person (the object shape personOut returns). */
export function savePerson(p) {
  const row = {
    id: p.id, name: p.name, title: p.title ?? null, domain: p.domain, org_id: p.orgId ?? null, company: p.company ?? null, role: p.role ?? null,
    seniority: p.seniority ?? null, email: p.email ?? null, confidence: p.confidence ?? null, pattern: p.pattern ?? null,
    alternatives: j(p.alternatives ?? null), phone: p.phone ?? null, sources: j(p.sources ?? []), from_site: p.fromSite ? 1 : 0,
    looked_up: p.lookedUp ? 1 : 0, at: p.at ?? now(), updated_at: p.updatedAt ?? now(),
    f_text: fold([p.name, p.role, p.company, p.domain].filter(Boolean).join(" | ")),
    origin: p.origin ?? (p.fromSite ? "site" : p.lookedUp ? "lookup" : null),
  };
  db().prepare(`INSERT OR REPLACE INTO people(${PEOPLE_COLS.join(",")}) VALUES(${PEOPLE_COLS.map((c) => "@" + c).join(",")})`).run(row);
}
export const getPerson = (id) => personOut(db().prepare("SELECT * FROM people WHERE id=?").get(id));

// ── Nekontaktovať ──────────────────────────────────────────────────────────────────────────────────────────────────

export const blockedList = () => db().prepare("SELECT target FROM blocked ORDER BY at").pluck().all();

/** Keeps ~/.scout/blocked.json in step with the table (Courier checks it before sending a sequence e-mail). */
export function writeBlockedJson() {
  const list = blockedList();
  writeFileSync(BLOCKED_JSON + ".tmp", JSON.stringify({ blocked: list, updatedAt: now() }, null, 1));
  renameSync(BLOCKED_JSON + ".tmp", BLOCKED_JSON);
}

export function isBlockedEmail(email) {
  if (!email) return false;
  const e = String(email).toLowerCase();
  return !!db().prepare("SELECT 1 FROM blocked WHERE target IN (?, ?)").get(e, e.split("@")[1] ?? "");
}

// ── The old store.json, imported once ──────────────────────────────────────────────────────────────────────────────

function importLegacy(d) {
  const file = join(DATA_DIR, "store.json");
  if (d.prepare("SELECT value FROM meta WHERE key='legacy_imported'").pluck().get() || !existsSync(file)) {
    if (!existsSync(BLOCKED_JSON)) { handle = d; writeBlockedJson(); }
    return;
  }
  const s = JSON.parse(readFileSync(file, "utf8"));
  handle = d;
  d.transaction(() => {
    for (const c of Object.values(s.companies ?? {})) {
      let orgId = null;
      if (c.org?.ico && c.org?.name) orgId = upsertOrg(c.org);
      d.prepare("INSERT OR REPLACE INTO sites(domain,org_id,ico,country,crawled_at,mx,pattern,pages,team) VALUES(?,?,?,?,?,?,?,?,?)")
        .run(c.domain, orgId, c.org?.ico ?? null, c.org?.country ?? null, c.crawledAt, j(c.mx), j(c.pattern), j(c.pages ?? []), j(c.team ?? []));
      for (const e of c.emails ?? []) d.prepare("INSERT OR REPLACE INTO emails VALUES(?,?,?,?,?,?,?,?,?)")
        .run(c.domain, e.email, e.kind, e.name ?? null, e.how ?? null, e.url ?? null, e.context ?? null, e.foundAt ?? c.crawledAt, e.own ? 1 : 0);
      for (const p of c.phones ?? []) d.prepare("INSERT OR REPLACE INTO phones VALUES(?,?,?,?,?,?,?)")
        .run(c.domain, p.phone, p.raw ?? null, p.how ?? null, p.url ?? null, p.context ?? null, p.foundAt ?? c.crawledAt);
      for (const x of c.socials ?? []) d.prepare("INSERT OR REPLACE INTO socials VALUES(?,?,?,?,?)").run(c.domain, x.kind, x.url, x.page ?? null, x.text ?? null);
    }
    for (const [id, p] of Object.entries(s.people ?? {})) {
      const orgId = d.prepare("SELECT org_id FROM sites WHERE domain=?").pluck().get(p.domain) ?? null;
      savePerson({ ...p, id: p.id ?? id, orgId, at: p.at ?? now(), updatedAt: p.updatedAt ?? p.at ?? now() });
    }
    for (const [key, l] of Object.entries(s.lists ?? {})) {
      d.prepare("INSERT OR REPLACE INTO lists VALUES(?,?,?,?)").run(key, l.name, l.createdAt, l.updatedAt ?? null);
      for (const m of l.members ?? []) d.prepare("INSERT OR IGNORE INTO list_members VALUES(?,?,?)").run(key, m, l.updatedAt ?? l.createdAt);
    }
    for (const t of s.blocked ?? []) d.prepare("INSERT OR IGNORE INTO blocked VALUES(?,?)").run(t, now());
    d.prepare("INSERT OR REPLACE INTO meta VALUES('legacy_imported', ?)").run(now());
  })();
  writeBlockedJson();
  renameSync(file, file + ".imported");   // kept as a backup; Scout no longer reads it
}
