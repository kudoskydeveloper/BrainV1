// Prospector: every registered company, filtered the way BizMachine / Apollo do it, with the total count, sorting and paging.
// Runs on the indexes from db.js (full text, country+region, NACE division, size, legal form, founded).
import { db, fold, orgOut } from "./db.js";

/** NACE Rev. 2 sections (Slovak names) → their divisions. */
export const SECTIONS = [
  ["A", "Poľnohospodárstvo, lesníctvo, rybolov", "01", "03"], ["B", "Ťažba a dobývanie", "05", "09"], ["C", "Priemyselná výroba", "10", "33"],
  ["D", "Energetika (elektrina, plyn, para)", "35", "35"], ["E", "Voda, odpad, sanácia", "36", "39"], ["F", "Stavebníctvo", "41", "43"],
  ["G", "Veľkoobchod a maloobchod, autá", "45", "47"], ["H", "Doprava a skladovanie", "49", "53"], ["I", "Ubytovanie a gastro", "55", "56"],
  ["J", "IT, médiá a telekomunikácie", "58", "63"], ["K", "Financie a poisťovníctvo", "64", "66"], ["L", "Nehnuteľnosti", "68", "68"],
  ["M", "Odborné, vedecké a technické služby", "69", "75"], ["N", "Administratívne a podporné služby", "77", "82"], ["O", "Verejná správa", "84", "84"],
  ["P", "Vzdelávanie", "85", "85"], ["Q", "Zdravotníctvo a sociálna pomoc", "86", "88"], ["R", "Umenie, zábava a rekreácia", "90", "93"],
  ["S", "Ostatné služby", "94", "96"], ["T", "Domácnosti ako zamestnávatelia", "97", "98"], ["U", "Extrateritoriálne organizácie", "99", "99"],
].map(([code, name, from, to]) => ({ code, name, from, to }));

const SORTS = {
  revenue_desc: "o.revenue IS NULL, o.revenue DESC",
  name: "o.name", founded_desc: "o.founded DESC", founded: "o.founded", size_desc: "o.size_rank DESC, o.name COLLATE NOCASE",
};
const SIZE_RANK = "CASE o.size WHEN '1-9' THEN 1 WHEN '10-49' THEN 2 WHEN '50-249' THEN 3 WHEN '250-999' THEN 4 WHEN '1000+' THEN 5 ELSE 0 END";
const many = (v) => (v == null || v === "" ? [] : Array.isArray(v) ? v : String(v).split(",")).filter(Boolean);
const ph = (a) => a.map(() => "?").join(",");

/** Words → an FTS5 query of word prefixes ("komf brat" → komf* AND brat*). */
const ftsQuery = (q) => fold(q).split(/[^a-z0-9]+/).filter((w) => w.length >= 2).map((w) => `"${w}"*`).join(" ");

export function build(f) {
  const w = ["o.name IS NOT NULL"], a = [];
  if (!f.includeDissolved) w.push("o.dissolved IS NULL");
  if (f.q) {
    const fq = ftsQuery(f.q);
    const ico = String(f.q).replace(/\s/g, "");
    if (/^\d{6,8}$/.test(ico)) { w.push("o.ico = ?"); a.push(ico.padStart(8, "0")); }
    else if (fq) { w.push("o.id IN (SELECT rowid FROM orgs_fts WHERE orgs_fts MATCH ?)"); a.push(fq); }
  }
  const country = many(f.country);
  if (country.length) { w.push(`o.country IN (${ph(country)})`); a.push(...country); }
  const region = many(f.region);
  if (region.length) { w.push(`o.region IN (${ph(region)})`); a.push(...region); }
  if (f.city) { w.push("o.f_place LIKE ?"); a.push(`%${fold(f.city)}%`); }
  // industry: sections (A–U), divisions or longer NACE prefixes, or words of the industry name
  const nace = many(f.nace).concat(many(f.section));
  if (nace.length) {
    const ors = [];
    for (const n of nace) {
      const s = SECTIONS.find((x) => x.code === String(n).toUpperCase());
      if (s) { ors.push("o.nace2 BETWEEN ? AND ?"); a.push(s.from, s.to); }
      else if (/^\d{2}$/.test(n)) { ors.push("o.nace2 = ?"); a.push(n); }
      else {   // a code prefix as a range, so the index is used: 6201 → [6201, 6202)
        const c = String(n).replace(/\D/g, "");
        ors.push("(o.nace >= ? AND o.nace < ?)"); a.push(c, c.slice(0, -1) + String.fromCharCode(c.charCodeAt(c.length - 1) + 1));
      }
    }
    w.push(`(${ors.join(" OR ")})`);
  }
  if (f.industry) { w.push("o.f_industry LIKE ?"); a.push(`%${fold(f.industry)}%`); }
  const size = many(f.size);
  if (size.length) { w.push(`o.size IN (${ph(size)})`); a.push(...size); }
  const form = many(f.legalForm);
  if (form.length) { w.push(`o.legal_form IN (${ph(form)})`); a.push(...form); }
  if (f.foundedFrom) { w.push("o.founded >= ?"); a.push(`${f.foundedFrom}`); }
  if (f.foundedTo) { w.push("o.founded <= ?"); a.push(`${f.foundedTo}-12-31`); }
  if (f.revenueFrom) { w.push("o.revenue >= ?"); a.push(Number(f.revenueFrom)); }
  if (f.revenueTo) { w.push("o.revenue <= ?"); a.push(Number(f.revenueTo)); }
  if (f.enriched === true || f.enriched === "yes") w.push("o.enriched_at IS NOT NULL");
  if (f.enriched === false || f.enriched === "no") w.push("o.enriched_at IS NULL");
  if (f.withSite) w.push("EXISTS (SELECT 1 FROM sites s WHERE s.org_id = o.id)");
  if (f.withPeople) w.push("EXISTS (SELECT 1 FROM people p WHERE p.org_id = o.id)");
  if (f.list) { w.push("('org:' || o.country || ':' || o.ico IN (SELECT member FROM list_members WHERE list_key = ?) OR EXISTS (SELECT 1 FROM sites s WHERE s.org_id = o.id AND s.domain IN (SELECT member FROM list_members WHERE list_key = ?)))"); a.push(f.listKey, f.listKey); }
  return { where: w.length ? "WHERE " + w.join(" AND ") : "", args: a };
}

/** { total, rows }: one page of companies matching the filters, with how many konatelia / addresses Scout has for each. */
export function prospect(f = {}) {
  const d = db();
  const { where, args } = build(f);
  const limit = Math.min(500, Math.max(1, Number(f.limit) || 100));
  const offset = Math.max(0, Number(f.offset) || 0);
  const total = f.noCount ? null : d.prepare(`SELECT count(*) FROM orgs o ${where}`).pluck().get(...args);
  const order = SORTS[f.sort] ?? SORTS.founded_desc;   // newest first, like a prospecting tool
  const rows = d.prepare(`SELECT o.*, ${SIZE_RANK} AS size_rank FROM orgs o ${where} ORDER BY ${order.replaceAll("o.size_rank", "size_rank")} LIMIT ? OFFSET ?`)
    .all(...args, limit, offset);
  const site = d.prepare("SELECT domain FROM sites WHERE org_id = ? ORDER BY crawled_at DESC LIMIT 1").pluck();
  const people = d.prepare("SELECT count(*) FROM people WHERE org_id = ?").pluck();
  const emails = d.prepare("SELECT count(*) FROM emails e JOIN sites s ON s.domain = e.domain WHERE s.org_id = ? AND e.own = 1").pluck();
  return {
    total, offset, limit,
    rows: rows.map((r) => ({ id: `${r.country}:${r.ico}`, ...orgOut(r), domain: site.get(r.id) ?? null, people: people.get(r.id), emails: emails.get(r.id) })),
  };
}

/** People search with the company filters (country, kraj, industry, size, revenue …) plus their own: name or role words,
 *  seniority, origin (registry / site / lookup), with an address, the address's confidence. { total, rows } like prospect(). */
export function prospectPeople(f = {}) {
  const d = db();
  // company filters narrow the companies first (indexed); without them, people are searched directly
  const orgFilters = ["company", "country", "region", "city", "nace", "section", "industry", "size", "legalForm", "foundedFrom", "foundedTo", "revenueFrom", "revenueTo", "withSite", "list"]
    .some((k) => many(f[k]).length || (f[k] && !Array.isArray(f[k])));
  // when the people side is the narrow one (a name, only those with an address), start from people and check their company;
  // otherwise start from the companies the filters allow
  const peopleFirst = !!(f.q || f.withEmail || many(f.confidence).length || many(f.origin).some((x) => x !== "registry"));
  const w = [], a = [];
  if (orgFilters) {
    const o = build({ ...f, q: f.company });
    if (peopleFirst) { if (o.where) w.push(o.where.replace(/^WHERE /, "")); }
    else w.push(`p.org_id IN (SELECT o.id FROM orgs o ${o.where})`);
    a.push(...o.args);
  } else if (!f.includeDissolved) w.push("o.dissolved IS NULL");
  if (f.q) { const fq = ftsQuery(f.q); if (fq) { w.push("p.rowid IN (SELECT rowid FROM people_fts WHERE people_fts MATCH ?)"); a.push(fq); } }
  if (f.role) { w.push("p.role LIKE ?"); a.push(`%${f.role}%`); }
  const sen = many(f.seniority);
  if (sen.length) { w.push(`p.seniority IN (${ph(sen)})`); a.push(...sen); }
  const origin = many(f.origin);
  if (origin.length) { w.push(`p.origin IN (${ph(origin)})`); a.push(...origin); }
  if (f.withEmail) w.push("p.email IS NOT NULL AND p.email NOT IN (SELECT target FROM blocked)");
  const conf = many(f.confidence);
  if (conf.length) { w.push(`p.confidence IN (${ph(conf)})`); a.push(...conf); }
  const where = w.length ? "WHERE " + w.join(" AND ") : "";
  const from = "FROM people p JOIN orgs o ON o.id = p.org_id";
  const limit = Math.min(500, Math.max(1, Number(f.limit) || 100));
  const offset = Math.max(0, Number(f.offset) || 0);
  const total = f.noCount ? null : d.prepare(`SELECT count(*) ${from} ${where}`).pluck().get(...a);
  const order = { name: "p.name", company: "o.name, p.name", revenue_desc: "o.revenue IS NULL, o.revenue DESC, p.name", recent: "p.updated_at DESC" }[f.sort] ?? "p.updated_at DESC";
  const rows = d.prepare(`SELECT p.*, o.country, o.ico, o.name AS org_name, o.city, o.region, o.industry, o.nace, o.size, o.employees, o.revenue
    ${from} ${where} ORDER BY ${order} LIMIT ? OFFSET ?`).all(...a, limit, offset);
  const blocked = d.prepare("SELECT 1 FROM blocked WHERE target IN (?, ?)");
  return {
    total, offset, limit,
    rows: rows.map((r) => ({ id: r.id, name: r.name, title: r.title ?? undefined, role: r.role ?? undefined, seniority: r.seniority ?? undefined,
      email: r.email ?? undefined, confidence: r.confidence ?? undefined, phone: r.phone ?? undefined, domain: r.domain ?? undefined, origin: r.origin ?? undefined,
      orgId: `${r.country}:${r.ico}`, company: r.org_name, city: r.city ?? undefined, region: r.region ?? undefined, industry: r.industry ?? undefined,
      nace: r.nace ?? undefined, size: r.size ?? undefined, employees: r.employees ?? undefined, revenue: r.revenue ?? undefined,
      blocked: r.email && blocked.get(r.email, r.email.split("@")[1]) ? true : undefined })),
  };
}

/** Everything about one company: the registry record, its people (konatelia and from its website) and its websites. */
export function orgDetail(id) {
  const [country, ico] = String(id).toUpperCase().split(":");
  const d = db();
  const r = d.prepare("SELECT * FROM orgs WHERE country = ? AND ico = ?").get(country, (ico ?? "").padStart(8, "0"));
  if (!r) throw new Error(`Company ${id} is not in the register.`);
  return {
    id: `${r.country}:${r.ico}`, ...orgOut(r),
    sites: d.prepare("SELECT domain, crawled_at AS crawledAt FROM sites WHERE org_id = ? ORDER BY crawled_at DESC").all(r.id),
    people: d.prepare("SELECT * FROM people WHERE org_id = ? ORDER BY origin = 'registry' DESC, name").all(r.id).map((p) => ({
      id: p.id, name: p.name, title: p.title ?? undefined, role: p.role ?? undefined, seniority: p.seniority ?? undefined, email: p.email ?? undefined,
      confidence: p.confidence ?? undefined, domain: p.domain ?? undefined, origin: p.origin ?? undefined, sources: JSON.parse(p.sources ?? "[]") })),
  };
}

/** The values the filters can take (for the app's pickers): regions per country, legal forms, sections, sizes. */
export function facets({ fresh = false } = {}) {
  const d = db();
  const cached = !fresh && d.prepare("SELECT value FROM meta WHERE key='facets'").pluck().get();
  if (cached) return JSON.parse(cached);
  const out = {
    regions: d.prepare("SELECT country, region, count(*) AS n FROM orgs WHERE dissolved IS NULL AND region IS NOT NULL GROUP BY 1, 2 ORDER BY 1 DESC, 2").all(),
    legalForms: d.prepare("SELECT legal_form AS form, count(*) AS n FROM orgs WHERE dissolved IS NULL AND legal_form IS NOT NULL GROUP BY 1 HAVING n > 500 ORDER BY n DESC").all(),
    sections: SECTIONS.map(({ code, name }) => ({ code, name })),
    sizes: ["1-9", "10-49", "50-249", "250-999", "1000+"],
  };
  d.prepare("INSERT OR REPLACE INTO meta VALUES('facets', ?)").run(JSON.stringify(out));   // counting 2 mil. rows takes ~10 s: refreshed by scout update
  return out;
}

/** A filtered set (or a list) of companies as CSV: what BizMachine exports. */
export function exportCompaniesCsv(f = {}) {
  const all = [];
  for (let offset = 0; ; offset += 500) {
    const p = prospect({ ...f, limit: 500, offset, noCount: true });
    all.push(...p.rows);
    if (p.rows.length < 500 || all.length >= (f.max ?? 50_000)) break;
  }
  const cols = ["ico", "country", "name", "legalForm", "address", "city", "region", "founded", "nace", "industry", "employees", "size", "domain", "people", "emails"];
  const q = (v) => (v == null ? "" : /[",\n;]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v));
  return [cols.join(","), ...all.map((r) => cols.map((c) => q(r[c])).join(","))].join("\n");
}
