// Company data from the public registries, by IČO: RegisterUZ (SK, Register účtovných závierok) and ARES (CZ). Name, legal form,
// registered address, founding date, industry (SK NACE / CZ-NACE) and size by employees. Both are free, official and need no key.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { UA } from "./crawl.js";

const RUZ = "https://www.registeruz.sk/cruz-public/api";
const ARES = "https://ares.gov.cz/ekonomicke-subjekty-v-be/rest";

async function json(url) {
  const r = await fetch(url, { headers: { "user-agent": UA, accept: "application/json" }, signal: AbortSignal.timeout(15_000) });
  if (r.status === 404) return null;
  if (!r.ok) throw new Error(`${r.status} ${url}`);
  return r.json();
}

// legal forms are the same codes in both countries for the common ones
export const LEGAL = { 101: "živnostník", 102: "živnostník", 107: "SZČO", 111: "v.o.s.", 112: "s.r.o.", 113: "k.s.", 117: "nadácia", 118: "nadácia",
  121: "a.s.", 141: "o.p.s.", 145: "j.s.a.", 205: "družstvo", 301: "štátny podnik", 331: "príspevková organizácia", 421: "zahraničná osoba",
  701: "združenie", 706: "spolok", 801: "obec" };

export const SK_REGION = { SK010: "Bratislavský", SK021: "Trnavský", SK022: "Trenčiansky", SK023: "Nitriansky", SK031: "Žilinský",
  SK032: "Banskobystrický", SK041: "Prešovský", SK042: "Košický" };

// CZ (ČSÚ) employee categories
export const CZ_SIZE = { 110: "0", 120: "1-5", 130: "6-9", 210: "10-19", 220: "20-24", 230: "25-49", 240: "50-99", 310: "100-199", 320: "200-249",
  330: "250-499", 340: "500-999", 410: "1000-1499", 420: "1500-1999", 430: "2000-2499", 440: "2500-2999", 450: "3000-3999", 460: "4000-4999",
  470: "5000-9999", 480: "10000+" };

/** Size bucket (Apollo-style) from an employee range like "25-49", for filtering. */
export function sizeBucket(range) {
  const n = parseInt(String(range ?? "").replace(/\D.*$/, ""), 10);
  if (Number.isNaN(n)) return null;
  return n < 10 ? "1-9" : n < 50 ? "10-49" : n < 250 ? "50-249" : n < 1000 ? "250-999" : "1000+";
}

// code lists from RegisterUZ, cached on disk (they change about once a decade)
let lists;
export async function codeLists(dir) {
  if (lists) return lists;
  const file = dir && join(dir, "codes.json");
  if (file && existsSync(file)) return (lists = JSON.parse(readFileSync(file, "utf8")));
  const [nace, size] = await Promise.all([json(`${RUZ}/sk-nace`), json(`${RUZ}/velkosti-organizacie`)]);
  const map = (d) => Object.fromEntries(d.klasifikacie.map((k) => [k.kod, k.nazov.sk]));
  lists = { nace: map(nace), size: map(size) };
  if (file) { mkdirSync(dir, { recursive: true }); writeFileSync(file, JSON.stringify(lists)); }
  return lists;
}
// a CZ-NACE code may be shorter or longer than the SK one: the closest code with the same start
export const naceName = (nace, code) => {
  if (!code) return null;
  for (let c = String(code); c.length >= 2; c = c.slice(0, -1)) {
    if (nace[c]) return nace[c];
    const k = Object.keys(nace).find((x) => x.startsWith(c));
    if (k && c.length >= 4) return nace[k];
  }
  return null;
};

async function sk(ico, codes) {
  const ids = await json(`${RUZ}/uctovne-jednotky?zmenene-od=2000-01-01&ico=${ico}`);
  if (!ids?.id?.length) return null;
  const u = await json(`${RUZ}/uctovna-jednotka?id=${ids.id[ids.id.length - 1]}`);
  if (!u) return null;
  const employees = codes.size[u.velkostOrganizacie]?.replace(/ zamestnan\p{L}*/u, "") ?? null;
  return {
    country: "SK", ico: u.ico, name: u.nazovUJ, legalForm: LEGAL[u.pravnaForma] ?? u.pravnaForma, dic: u.dic ?? null,
    address: [u.ulica, [u.psc, u.mesto].filter(Boolean).join(" ")].filter(Boolean).join(", "), city: u.mesto ?? null, region: SK_REGION[u.kraj] ?? u.kraj ?? null,
    founded: u.datumZalozenia ?? null, nace: u.skNace ?? null, industry: naceName(codes.nace, u.skNace),
    employees: employees === "nezistený" ? null : employees, size: sizeBucket(employees),
    source: `https://www.registeruz.sk/cruz-public/domain/accountingentity/show/${u.id}`,
  };
}

async function cz(ico, codes) {
  const [b, res] = await Promise.all([json(`${ARES}/ekonomicke-subjekty/${ico}`), json(`${ARES}/ekonomicke-subjekty-res/${ico}`).catch(() => null)]);
  if (!b) return null;
  const r = res?.zaznamy?.find((z) => z.primarniZaznam) ?? res?.zaznamy?.[0];
  const nace = r?.czNacePrevazujici2008 ?? r?.czNacePrevazujici ?? b.czNace2008?.find((c) => c.length === 5) ?? null;
  const employees = CZ_SIZE[r?.statistickeUdaje?.kategoriePoctuPracovniku] ?? null;
  return {
    country: "CZ", ico: b.ico, name: b.obchodniJmeno, legalForm: LEGAL[b.pravniForma] ?? b.pravniForma, dic: b.dic ?? null,
    address: b.sidlo?.textovaAdresa ?? null, city: b.sidlo?.nazevObce ?? null, region: b.sidlo?.nazevKraje ?? null,
    founded: b.datumVzniku ?? null, nace, industry: naceName(codes.nace, nace), employees, size: sizeBucket(employees),
    source: `https://ares.gov.cz/ekonomicke-subjekty?ico=${ico}`,
  };
}

/** The company registered under an IČO; `country` (SK/CZ) is tried first, then the other. null when neither knows it. */
export async function lookup(ico, { country, dir } = {}) {
  const id = String(ico).replace(/\D/g, "").padStart(8, "0");
  if (id.length !== 8) return null;
  const codes = await codeLists(dir);
  for (const c of country === "CZ" ? ["CZ", "SK"] : ["SK", "CZ"]) {
    try {
      const r = c === "SK" ? await sk(id, codes) : await cz(id, codes);
      if (r) return { ...r, fetchedAt: new Date().toISOString() };
    } catch {}
  }
  return null;
}

/** The company's own IČO among those on its site: the most frequent; SK/CZ from IČ DPH, DIČ or the domain. */
export function pickIco(ids, domain) {
  const count = {};
  for (const i of ids.ico) count[i] = (count[i] ?? 0) + 1;
  const ico = Object.entries(count).sort((a, b) => b[1] - a[1])[0]?.[0] ?? null;
  const country = ids.vat.some((v) => v.startsWith("SK")) || domain.endsWith(".sk") ? "SK"
    : ids.vat.some((v) => v.startsWith("CZ")) || ids.dic.some((d) => d.startsWith("CZ")) || domain.endsWith(".cz") ? "CZ" : undefined;
  return ico ? { ico, country } : null;
}
