// Bulk import of every registered company, from the official open data (no crawling, no per-company requests):
//   CZ  ČSÚ "Registr ekonomických subjektů" (RES), one CSV twice a month: IČO, name, legal form, founded/dissolved,
//       CZ-NACE, employee category, address.  https://csu.gov.cz/statistika/registr-ekonomickych-subjektu-otevrena-data-dokumentace
//   SK  ŠÚ SR "Register právnických osôb" (RPO), a full JSON dump plus daily changes in a public bucket: IČO, name, legal form,
//       founded/terminated, SK NACE, address, and the statutory bodies (konatelia, predstavenstvo …).
//
// Data minimisation (GDPR): only legal entities, not sole traders (their "company" is a person with a home address); for
// people only the current statutory bodies of live companies, by name and role, never their home address or birth date.
import { createReadStream, createWriteStream, existsSync, mkdirSync, readdirSync, renameSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { createGunzip } from "node:zlib";
import { DATA_DIR, db, fold, now } from "./db.js";
import { seniority } from "./extract.js";
import { UA } from "./crawl.js";
import { CZ_SIZE, LEGAL, SK_REGION, codeLists, naceName, sizeBucket } from "./registry.js";

export const BULK_DIR = join(DATA_DIR, "bulk");

const CZ_REGION = { CZ010: "Praha", CZ020: "Středočeský", CZ031: "Jihočeský", CZ032: "Plzeňský", CZ041: "Karlovarský", CZ042: "Ústecký",
  CZ051: "Liberecký", CZ052: "Královéhradecký", CZ053: "Pardubický", CZ063: "Vysočina", CZ064: "Jihomoravský", CZ071: "Olomoucký",
  CZ072: "Zlínský", CZ080: "Moravskoslezský" };

/** Sole traders and other natural persons: skipped. SK and CZ share the 10x codes. */
const isPerson = (form) => /^10\d$/.test(String(form ?? ""));

function lines(file) {
  const input = createReadStream(file);
  return createInterface({ input: file.endsWith(".gz") ? input.pipe(createGunzip()) : input, crlfDelay: Infinity });
}

/** One CSV line (quotes, doubled quotes, commas inside quotes; RES has no newlines inside fields). */
export function csvLine(l) {
  const out = [];
  let cur = "", q = false;
  for (let i = 0; i < l.length; i++) {
    const c = l[i];
    if (q) { if (c === '"') { if (l[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += c; }
    else if (c === '"') q = true;
    else if (c === ",") { out.push(cur); cur = ""; }
    else cur += c;
  }
  out.push(cur);
  return out;
}

function upsertStmt() {
  return db().prepare(`INSERT INTO orgs(country,ico,name,legal_form,address,city,region,founded,dissolved,nace,industry,employees,size,source,fetched_at,f_text,f_industry,f_place)
    VALUES(@country,@ico,@name,@legalForm,@address,@city,@region,@founded,@dissolved,@nace,@industry,@employees,@size,@source,@at,@f,@fi,@fp)
    ON CONFLICT(country,ico) DO UPDATE SET name=excluded.name, legal_form=excluded.legal_form, address=excluded.address, city=excluded.city,
      region=excluded.region, founded=excluded.founded, dissolved=excluded.dissolved, nace=COALESCE(excluded.nace,nace),
      industry=COALESCE(excluded.industry,industry), employees=COALESCE(excluded.employees,employees), size=COALESCE(excluded.size,size),
      source=COALESCE(source,excluded.source), fetched_at=excluded.fetched_at, f_text=excluded.f_text, f_industry=COALESCE(excluded.f_industry,f_industry),
      f_place=excluded.f_place`);
}
const orgRow = (o) => ({ ...o, f: fold([o.name, o.industry, o.city, o.region].filter(Boolean).join(" | ")),
  fi: o.industry ? fold(o.industry) : null, fp: fold([o.city, o.region, o.address].filter(Boolean).join(" | ")) });

/** Runs `rows` (an async iterable of org objects) into the database in transactions of 5 000. */
async function load(rows, { log = () => {}, extra } = {}) {
  const d = db();
  const up = upsertStmt();
  let batch = [], n = 0;
  const flush = d.transaction((b) => { for (const o of b) { up.run(orgRow(o)); extra?.(o); } });
  for await (const o of rows) {
    batch.push(o);
    if (batch.length === 5000) { flush(batch); n += batch.length; batch = []; if (n % 50_000 === 0) log(`${n.toLocaleString("sk")} …`); }
  }
  flush(batch);
  return n + batch.length;
}

// ── CZ ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

export async function importCZ(file = join(BULK_DIR, "res_data.csv.gz"), { log = () => {} } = {}) {
  if (!existsSync(file)) throw new Error(`Missing ${file}: download https://opendata.csu.gov.cz/soubory/od/od_org03/res_data.csv first.`);
  const { nace } = await codeLists(DATA_DIR);
  const at = now();
  const stats = { read: 0, skippedPersons: 0, imported: 0, live: 0 };
  async function* rows() {
    let head;
    for await (const l of lines(file)) {
      if (!head) { head = csvLine(l.replace(/^﻿/, "")); continue; }
      const c = csvLine(l);
      const r = Object.fromEntries(head.map((h, i) => [h, c[i] ?? ""]));
      stats.read++;
      if (!r.ICO || isPerson(r.FORMA)) { stats.skippedPersons++; continue; }
      const employees = CZ_SIZE[r.KATPO] ?? null;
      const code = r.NACE || r.NACE2025 || null;   // NACE Rev. 2 like SK; 2025 codes only when that is all there is
      const street = [r.ULICE_TEXT || r.COBCE_TEXT, [r.CDOM, r.COR].filter(Boolean).join("/")].filter(Boolean).join(" ");
      if (!r.DDATZAN) stats.live++;
      yield {
        country: "CZ", ico: r.ICO.padStart(8, "0"), name: r.FIRMA || null, legalForm: LEGAL[r.FORMA] ?? r.FORMA ?? null,
        address: r.TEXTADR || [street, [r.PSC, r.OBEC_TEXT].filter(Boolean).join(" ")].filter(Boolean).join(", ") || null,
        city: r.OBEC_TEXT || null, region: CZ_REGION[String(r.OKRESLAU).slice(0, 5)] ?? null, founded: r.DDATVZN || null, dissolved: r.DDATZAN || null,
        nace: code, industry: naceName(nace, code), employees, size: sizeBucket(employees), source: "ČSÚ RES", at,
      };
    }
  }
  stats.imported = await load(rows(), { log });
  db().prepare("INSERT OR REPLACE INTO meta VALUES('import_cz', ?)").run(JSON.stringify({ at, ...stats }));
  return stats;
}

// ── SK ─────────────────────────────────────────────────────────────────────────────────────────────────────────────

const current = (list) => (list ?? []).filter((x) => !x.validTo).at(-1) ?? null;
const latest = (list) => current(list) ?? (list ?? []).at(-1) ?? null;

/** One RPO record → an org (null for sole traders) and its current statutory people. */
export function rpoRecord(r, nace) {
  const form = latest(r.legalForms)?.value?.code;
  const ico = latest(r.identifiers)?.value;
  if (!ico || isPerson(form)) return null;
  const a = latest(r.addresses);
  const muni = a?.municipality;
  const street = [a?.street, [a?.regNumber || null, a?.buildingNumber].filter(Boolean).join("/")].filter(Boolean).join(" ");
  const code = r.statisticalCodes?.mainActivity?.code ?? null;
  const org = {
    country: "SK", ico: ico.padStart(8, "0"), name: latest(r.fullNames)?.value ?? null, legalForm: LEGAL[form] ?? latest(r.legalForms)?.value?.value ?? null,
    address: [street, [a?.postalCodes?.[0], muni?.value].filter(Boolean).join(" ")].filter(Boolean).join(", ") || null, city: muni?.value ?? null,
    region: SK_REGION[String(muni?.code ?? "").slice(0, 5)] ?? null, founded: r.establishment ?? null, dissolved: r.termination ?? null,
    nace: code, industry: r.statisticalCodes?.mainActivity?.value ?? naceName(nace, code), employees: null, size: null, source: "ŠÚ SR RPO",
  };
  // a liquidator runs a company that is being wound up: neither they nor the company are prospects
  const people = org.dissolved ? [] : (r.statutoryBodies ?? []).filter((s) => !s.validTo && s.personName && !/likvid/i.test(s.stakeholderType?.value ?? "")).map((s) => {
    const n = s.personName;
    const name = n.formatedName?.replace(/,.*$/, "").trim() || [...(n.givenNames ?? []), ...(n.familyNames ?? [])].join(" ");
    const title = (n.prefixes ?? []).map((p) => p.value).join(" ") || null;
    const role = s.stakeholderType?.value ?? "Štatutárny orgán";
    return { name: name.replace(/^(?:(?:Ing|Mgr|Bc|MUDr|JUDr|PhDr|RNDr|doc|prof|Dr|MBA|PhD)\.?\s+)+/i, ""), title, role, since: s.validFrom ?? null };
  }).filter((p) => p.name.split(/\s+/).length >= 2);
  return { org, people };
}

export async function importSK(dir = join(BULK_DIR, "rpo"), { log = () => {} } = {}) {
  const files = existsSync(dir) ? readdirSync(dir).filter((f) => /^init_.*\.json\.gz$/.test(f)).sort() : [];
  if (!files.length) throw new Error(`No RPO dump in ${dir}: download batch-init/*.json.gz from the susr-rpo bucket first.`);
  const stats = await applyRPO(files.map((f) => join(dir, f)), { log });
  const date = files[0].match(/\d{4}-\d{2}-\d{2}/)?.[0];
  db().prepare("INSERT OR REPLACE INTO meta VALUES('import_sk', ?)").run(JSON.stringify(stats));
  if (date) db().prepare("INSERT OR REPLACE INTO meta VALUES('sk_through', ?)").run(date);   // daily changes after this date still to apply
  return stats;
}

/** Applies RPO files (the full dump or daily changes: both are whole current records) to orgs and registry people. */
export async function applyRPO(paths, { log = () => {} } = {}) {
  const { nace } = await codeLists(DATA_DIR);
  const d = db();
  const at = now();
  const stats = { at, files: paths.length, read: 0, skippedPersons: 0, imported: 0, live: 0, people: 0 };
  const orgId = d.prepare("SELECT id FROM orgs WHERE country='SK' AND ico=?").pluck();
  const dropPeople = d.prepare("DELETE FROM people WHERE org_id=? AND origin='registry' AND id NOT IN (SELECT member FROM list_members)");
  const addPerson = d.prepare(`INSERT INTO people(id,name,title,domain,org_id,company,role,seniority,sources,at,updated_at,f_text,origin)
    VALUES(@id,@name,@title,NULL,@org,@company,@role,@seniority,@sources,@at,@at,@f,'registry')
    ON CONFLICT(id) DO UPDATE SET title=excluded.title, org_id=excluded.org_id, company=excluded.company, role=excluded.role, seniority=excluded.seniority,
      updated_at=excluded.updated_at, f_text=excluded.f_text`);
  const pending = new Map();   // ico → people, written right after their org
  async function* rows() {
    for (const f of paths) {
      log(f.split("/").pop());
      for await (const l of lines(f)) {
        const t = l.trim().replace(/^,/, "");
        if (!t.startsWith('{"id"')) continue;
        let r;
        try { r = JSON.parse(t.replace(/,$/, "")); } catch { continue; }
        stats.read++;
        const x = rpoRecord(r, nace);
        if (!x) { stats.skippedPersons++; continue; }
        if (!x.org.dissolved) stats.live++;
        pending.set(x.org.ico, x);
        yield { ...x.org, at };
      }
    }
  }
  const extra = (o) => {
    const x = pending.get(o.ico);
    pending.delete(o.ico);
    if (!x) return;
    const id = orgId.get(o.ico);
    dropPeople.run(id);   // the board as it is today: who left is gone
    for (const p of x.people) {
      const slug = fold(p.name).replace(/[^a-z]+/g, "-").replace(/^-|-$/g, "");
      addPerson.run({ id: `reg:SK:${o.ico}:${slug}`, name: p.name, title: p.title, org: id, company: o.name, role: p.role,
        seniority: seniority(p.role) === "staff" ? "owner" : seniority(p.role), sources: JSON.stringify([`RPO ${p.since ? "od " + p.since : ""}`.trim()]), at,
        f: fold([p.name, p.role, o.name].join(" | ")) });
      stats.people++;
    }
  };
  stats.imported = await load(rows(), { log, extra });
  return stats;
}

// ── Keeping up: SK every day, CZ when ČSÚ publishes a new file (twice a month) ───────────────────────────────────────

const RPO_BUCKET = "https://frkqbrydxwdp.compat.objectstorage.eu-frankfurt-1.oraclecloud.com/susr-rpo";
const RES_URL = "https://opendata.csu.gov.cz/soubory/od/od_org03/res_data.csv";
const meta = (k) => db().prepare("SELECT value FROM meta WHERE key=?").pluck().get(k);
const setMeta = (k, v) => db().prepare("INSERT OR REPLACE INTO meta VALUES(?, ?)").run(k, v);

async function download(url, file, headers = {}) {
  const r = await fetch(url, { headers: { "user-agent": UA, ...headers } });
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  mkdirSync(dirname(file), { recursive: true });
  await pipeline(Readable.fromWeb(r.body), createWriteStream(file + ".part"));
  renameSync(file + ".part", file);
  return r;
}

/** The daily change files after `after` (YYYY-MM-DD), oldest first. */
export async function rpoDailyAfter(after) {
  const keys = [];
  let token = null;
  do {
    const u = `${RPO_BUCKET}/?list-type=2&prefix=batch-daily/actual_&max-keys=1000${token ? "&continuation-token=" + encodeURIComponent(token) : ""}&start-after=batch-daily/actual_${after}.json.gz`;
    const x = await (await fetch(u, { headers: { "user-agent": UA } })).text();
    keys.push(...[...x.matchAll(/<Key>(batch-daily\/actual_(\d{4}-\d{2}-\d{2})\.json\.gz)<\/Key>/g)].map((m) => ({ key: m[1], date: m[2] })));
    token = x.match(/<NextContinuationToken>([^<]+)</)?.[1] ?? null;
  } while (token);
  return keys.filter((k) => k.date > after).sort((a, b) => a.date.localeCompare(b.date));
}

/** SK: every daily change file since the last one applied. CZ: the RES file again when ČSÚ has published a newer one. */
export async function update({ log = () => {} } = {}) {
  const out = { at: now() };
  // SK
  const through = meta("sk_through");
  if (!through) out.sk = "skipped: run `scout import sk` first";
  else {
    const days = await rpoDailyAfter(through);
    let applied = 0, records = 0;
    for (const d of days) {
      const file = join(BULK_DIR, "daily", d.key.split("/").pop());
      await download(`${RPO_BUCKET}/${d.key}`, file);
      const st = await applyRPO([file], { log });
      setMeta("sk_through", d.date);
      rmSync(file, { force: true });
      applied++; records += st.read;
    }
    out.sk = { days: applied, records, through: meta("sk_through") };
  }
  // CZ
  const head = await fetch(RES_URL, { method: "HEAD", headers: { "user-agent": UA } });
  const modified = head.headers.get("last-modified");
  if (!meta("import_cz")) out.cz = "skipped: run `scout import cz` first";
  else if (modified && modified === meta("cz_modified")) out.cz = { unchanged: modified };
  else {
    const file = join(BULK_DIR, "res_data.csv.gz");
    await download(RES_URL, file, { "accept-encoding": "gzip" });
    out.cz = await importCZ(file, { log });
    if (modified) setMeta("cz_modified", modified);
    rmSync(file, { force: true });
  }
  (await import("./prospect.js")).facets({ fresh: true });
  setMeta("last_update", JSON.stringify(out));
  return out;
}
