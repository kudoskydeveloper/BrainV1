import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { findIds, findPhones, findSocials, peopleIn, seniority } from "../src/extract.js";
import { pickIco, sizeBucket } from "../src/registry.js";

process.env.SCOUT_DIR = mkdtempSync(join(tmpdir(), "scout-"));
const scout = await import("../src/scout.js");

test("phones: tel links, +421/+420, SK mobiles; IČO is not a phone", () => {
  const got = findPhones(`<a href="tel:+421 905 123 456">x</a> Tel: 0905 111 222, +420 602 123 456, IČO: 12 345 678`).map((p) => p.phone);
  assert.deepEqual(got.sort(), ["+420602123456", "+421905111222", "+421905123456"]);
});

test("socials without share buttons", () => {
  const s = findSocials(`<a href="https://www.linkedin.com/company/acme/">L</a><a href="https://facebook.com/sharer.php?u=1">s</a><a href="https://cz.linkedin.com/in/jana">J</a>`, "https://a.sk");
  assert.deepEqual(s.map((x) => x.kind), ["linkedin", "linkedinPerson"]);
});

test("IČO, DIČ, IČ DPH and the company's own IČO", () => {
  const ids = findIds("Firma s.r.o., IČO: 47 123 456, DIČ: 2023456789, IČ DPH: SK2023456789. Partner IČO 11111111. IČO: 47123456");
  assert.deepEqual(pickIco(ids, "firma.com"), { ico: "47123456", country: "SK" });
  assert.equal(sizeBucket("25-49"), "10-49");
  assert.equal(sizeBucket("10000-19999"), "1000+");
});

test("people with roles from team pages; headings are not people", () => {
  const p = peopleIn("Náš tím\nIng. Jana Nováková\nkonateľka\nPeter Kováč – Head of Sales\nCEO Martin Horváth\nOchrana Osobných údajov\nObchodné podmienky");
  assert.deepEqual(p.map((x) => [x.name, x.seniority]), [["Jana Nováková", "owner"], ["Peter Kováč", "director"], ["Martin Horváth", "c-level"]]);
  assert.equal(seniority("Marketing manažérka"), "manager");
});

test("lists, search and CSV over the people database; blocked left out of CSV", async () => {
  const db = await import("../src/db.js");
  const orgId = db.upsertOrg({ country: "SK", ico: "12345678", name: "Firma s.r.o.", industry: "Počítačové programovanie", size: "10-49", region: "Bratislavský", city: "Bratislava" });
  db.db().prepare("INSERT INTO sites(domain,org_id,ico,country,crawled_at,mx,pattern,pages,team) VALUES(?,?,?,?,?,?,?,?,?)")
    .run("firma.sk", orgId, "12345678", "SK", new Date().toISOString(), "false", null, "[]", "[]");
  db.savePerson({ id: "jana-novakova@firma.sk", name: "Jana Nováková", domain: "firma.sk", orgId, role: "konateľka", seniority: "owner", email: "jana.novakova@firma.sk", confidence: "found" });
  db.savePerson({ id: "peter-kovac@firma.sk", name: "Peter Kováč", domain: "firma.sk", orgId, role: "Head of Sales", seniority: "director", email: "peter.kovac@firma.sk", confidence: "pattern" });
  assert.equal(scout.searchPeople({ seniority: ["owner"], industry: "programovanie" }).length, 1);
  assert.equal(scout.searchPeople({ q: "kovac" }).length, 1);
  assert.equal(scout.searchPeople({ industry: "firma" }).length, 0);   // industry doesn't match company names
  assert.equal(scout.searchCompanies({ size: ["10-49"], region: "bratislav" })[0].name, "Firma s.r.o.");
  scout.lists({ action: "add", name: "Q4 IT firmy", members: ["jana.novakova@firma.sk", "peter-kovac@firma.sk", "firma.sk"] });
  const l = scout.lists({ action: "show", name: "q4 it firmy" });
  assert.equal(l.people.length, 2);
  assert.equal(l.companies.length, 1);
  scout.block("peter.kovac@firma.sk");
  assert.equal(scout.searchPeople({ emailOnly: true }).length, 1);
  const csv = scout.exportCsv({ list: "Q4 IT firmy" }).split("\n");
  assert.equal(csv.length, 2);
  assert.match(csv[1], /jana\.novakova@firma\.sk/);
  assert.deepEqual(JSON.parse(readFileSync(join(process.env.SCOUT_DIR, "blocked.json"), "utf8")).blocked, ["peter.kovac@firma.sk"]);
  scout.forget("firma.sk");
  assert.equal(scout.lists({ action: "show", name: "Q4 IT firmy" }).people.length, 0);
  assert.ok(scout.block("x@y.sk").blocked.includes("firma.sk"));
});

test("the old store.json is imported once and kept as a backup", async () => {
  const dir = mkdtempSync(join(tmpdir(), "scout-legacy-"));
  writeFileSync(join(dir, "store.json"), JSON.stringify({
    companies: { "a.sk": { domain: "a.sk", crawledAt: "2026-11-01T00:00:00Z", mx: ["mx"], pages: [], emails: [{ email: "info@a.sk", kind: "generic", own: true }],
      org: { country: "SK", ico: "11111111", name: "A s.r.o.", size: "1-9" } } },
    people: { "jan-novak@a.sk": { name: "Ján Novák", domain: "a.sk", email: "jan.novak@a.sk", confidence: "mx", at: "2026-11-01T00:00:00Z" } },
    blocked: ["spam.sk"], lists: { test: { name: "Test", createdAt: "2026-11-01T00:00:00Z", members: ["jan-novak@a.sk"] } },
  }));
  const db = await import("../src/db.js");
  db.closeDb();
  const prev = process.env.SCOUT_DIR;
  process.env.SCOUT_DIR = dir;
  const fresh = await import(`../src/db.js?legacy=${Date.now()}`);
  const d = fresh.db();
  assert.equal(d.prepare("SELECT count(*) FROM sites").pluck().get(), 1);
  assert.equal(d.prepare("SELECT name FROM orgs").pluck().get(), "A s.r.o.");
  assert.equal(d.prepare("SELECT count(*) FROM list_members").pluck().get(), 1);
  assert.ok(existsSync(join(dir, "store.json.imported")) && !existsSync(join(dir, "store.json")));
  assert.deepEqual(JSON.parse(readFileSync(join(dir, "blocked.json"), "utf8")).blocked, ["spam.sk"]);
  fresh.closeDb();
  process.env.SCOUT_DIR = prev;
});

test("bulk: CSV lines with quotes, RPO records without sole traders or home addresses", async () => {
  const { csvLine, rpoRecord } = await import("../src/bulk.js");
  assert.deepEqual(csvLine('00000205,CZ0100,"Vojenské lesy a statky ČR, s.p.",,"a ""b"""'), ["00000205", "CZ0100", "Vojenské lesy a statky ČR, s.p.", "", 'a "b"']);
  const company = {
    identifiers: [{ value: "44618077", validFrom: "2009-02-18" }], fullNames: [{ value: "Cobra Partners s. r. o." }],
    legalForms: [{ value: { code: "112", value: "Spoločnosť s ručením obmedzeným" } }], establishment: "2009-02-18",
    addresses: [{ street: "Lietavská", buildingNumber: "12", postalCodes: ["85106"], municipality: { code: "SK0102528595", value: "Bratislava" } }],
    statisticalCodes: { mainActivity: { code: "8299", value: "Ostatné pomocné obchodné činnosti i. n." } },
    statutoryBodies: [
      { stakeholderType: { value: "Konateľ" }, validFrom: "2009-02-18", address: { street: "Domov 1" }, personName: { formatedName: "Ing. Marian Novotný", prefixes: [{ value: "Ing." }] } },
      { stakeholderType: { value: "Konateľ" }, validFrom: "2009-02-18", validTo: "2015-01-01", personName: { formatedName: "Bývalý Konateľ" } },
      { stakeholderType: { value: "Likvidátor" }, personName: { formatedName: "Ján Likvidátor" } },
    ],
  };
  const x = rpoRecord(company, {});
  assert.equal(x.org.ico, "44618077");
  assert.equal(x.org.region, "Bratislavský");
  assert.equal(x.org.legalForm, "s.r.o.");
  assert.deepEqual(x.people.map((p) => [p.name, p.title, p.role]), [["Marian Novotný", "Ing.", "Konateľ"]]);
  assert.ok(!JSON.stringify(x.people).includes("Domov"));
  assert.equal(rpoRecord({ ...company, legalForms: [{ value: { code: "101" } }] }, {}), null);
});

test("bulk: a daily change dissolving a company removes its registry people", async () => {
  const { applyRPO } = await import("../src/bulk.js");
  const { gzipSync } = await import("node:zlib");
  const db = await import("../src/db.js");
  const rec = (extra) => JSON.stringify({ id: 1, identifiers: [{ value: "55555555" }], fullNames: [{ value: "Nová firma s.r.o." }],
    legalForms: [{ value: { code: "112" } }], establishment: "2020-01-01", addresses: [{ municipality: { code: "SK0213", value: "Trnava" } }],
    statutoryBodies: [{ stakeholderType: { value: "Konateľ" }, personName: { formatedName: "Eva Malá" } }], ...extra });
  const file = (name, r) => { const f = join(process.env.SCOUT_DIR, name); writeFileSync(f, gzipSync(`{"exportDate":"x","results":[\n${r}\n]}`)); return f; };
  await applyRPO([file("d1.json.gz", rec({}))]);
  const people = () => db.db().prepare("SELECT name FROM people WHERE origin='registry' AND company='Nová firma s.r.o.'").pluck().all();
  assert.deepEqual(people(), ["Eva Malá"]);
  await applyRPO([file("d2.json.gz", rec({ termination: "2026-11-01" }))]);
  assert.deepEqual(people(), []);
  assert.equal(db.db().prepare("SELECT dissolved FROM orgs WHERE ico='55555555'").pluck().get(), "2026-11-01");
});

test("enrichment: domain guesses from the name, revenue and profit from a statement", async () => {
  const { candidates, nameWords, readStatement } = await import("../src/enrich.js");
  assert.deepEqual(nameWords("Init Labs s. r. o."), ["init", "labs"]);
  assert.deepEqual(nameWords("Bosch Rexroth, spol. s r.o."), ["bosch", "rexroth"]);
  assert.deepEqual(candidates("Firma B s. r. o.", "SK").slice(0, 2), ["firmab.sk", "firmab.com"]);
  assert.equal(candidates("Init Labs s. r. o.", "CZ")[0], "initlabs.cz");
  const tpl = { tabulky: [{ nazov: { sk: "Strana aktív" }, riadky: [] }, { nazov: { sk: "Výkaz ziskov a strát" }, riadky: [
    { text: { sk: "Čistý obrat (časť účt. tr. 6 podľa zákona)" } }, { text: { sk: "Tržby z predaja služieb" } },
    { text: { sk: "Výsledok hospodárenia za účtovné obdobie po zdanení (+/-)" } }] }] };
  const vykaz = { obsah: { tabulky: [{ data: [] }, { data: ["375070", "242873", "375070", "242873", "2639", "-14278"] }] } };
  assert.deepEqual(readStatement(tpl, vykaz), { revenue: 375070, revenuePrev: 242873, profit: 2639 });
});
