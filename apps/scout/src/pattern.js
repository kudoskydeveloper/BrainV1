// A company's address pattern (meno.priezvisko@, mpriezvisko@, …), learned from personal addresses found on its website by
// matching them to names on the same pages; and a person's likely address from it. Plus the MX check (does the domain take
// mail at all). No SMTP probing: from a home IP that gets you blacklisted, and many servers accept everything anyway.
import { promises as dns } from "node:dns";
import { isGeneric } from "./extract.js";

export const fold = (s) => String(s ?? "").normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();
const clean = (s) => fold(s).replace(/[^a-z]/g, "");

/** First and last name from "Ing. Jana Nováková, PhD." (titles and degrees dropped). */
export function splitName(full) {
  const words = String(full ?? "")
    .replace(/,.*$/, "")
    .split(/\s+/)
    .filter((w) => w && !/^(ing|mgr|bc|mudr|judr|phdr|rndr|doc|prof|dr|mba|phd|msc|csc|dipl|ing\.arch)\.?$/i.test(w.replace(/\.$/, "")));
  if (words.length < 2) return null;
  return { first: clean(words[0]), last: clean(words[words.length - 1]) };
}

export const PATTERNS = {
  "first.last": (n) => `${n.first}.${n.last}`,
  firstlast: (n) => `${n.first}${n.last}`,
  "f.last": (n) => `${n.first[0]}.${n.last}`,
  flast: (n) => `${n.first[0]}${n.last}`,
  first: (n) => n.first,
  "last.first": (n) => `${n.last}.${n.first}`,
  lastf: (n) => `${n.last}${n.first[0]}`,
  last: (n) => n.last,
  first_last: (n) => `${n.first}_${n.last}`,
  "first-last": (n) => `${n.first}-${n.last}`,
};
// how common each is in SK/CZ companies, for a guess when nothing was learned
const PRIOR = ["first.last", "flast", "first", "f.last", "firstlast", "last", "last.first"];

/** Names on the page: pairs of capitalised words (Ján Novák, Mária Kováčová). */
export function namesIn(text) {
  const out = new Set();
  // Unicode boundaries: in JS \b only knows ASCII, so "Nováková" (ending in á) would never match
  for (const m of String(text).matchAll(/(?<!\p{L})(\p{Lu}\p{Ll}+)\s+(\p{Lu}\p{Ll}+)(?!\p{L})/gu)) out.add(`${m[1]} ${m[2]}`);
  return [...out];
}

/** Which pattern a personal address follows, given the names on the site. */
export function learn(emails, text) {
  const names = namesIn(text).map(splitName).filter(Boolean);
  const votes = {};
  const examples = [];
  for (const e of emails) {
    if (isGeneric(e)) continue;
    const local = e.split("@")[0].toLowerCase();
    const domainWords = e.split("@")[1].split(/[.-]/);
    if (domainWords.some((w) => w.length > 3 && (local.includes(w) || w.includes(local)))) continue;   // kupele@kupelemesto.sk is the company, not a person
    for (const n of names) {
      const hit = Object.entries(PATTERNS).find(([, f]) => f(n) === local && local.length > 2);
      if (hit && !(hit[0] === "first" && names.filter((x) => x.first === n.first).length > 1)) {
        votes[hit[0]] = (votes[hit[0]] ?? 0) + 1;
        examples.push({ email: e, name: `${n.first} ${n.last}`, pattern: hit[0] });
        break;
      }
    }
  }
  // a one-word pattern (first@, last@) needs two people to be believed; two-part ones (first.last@) one
  const best = Object.entries(votes).filter(([p, n]) => n >= (p === "first" || p === "last" ? 2 : 1)).sort((a, b) => b[1] - a[1])[0];
  return best ? { pattern: best[0], votes: best[1], examples: examples.filter((x) => x.pattern === best[0]) } : null;
}

export async function hasMx(domain) {
  try {
    const mx = await dns.resolveMx(domain);
    return mx.length > 0 ? mx.sort((a, b) => a.priority - b.priority).map((m) => m.exchange) : false;
  } catch {
    return false;
  }
}

/**
 * The likely address of a person at a domain, with how sure it is:
 *   found    — the exact address is on the company's website
 *   pattern  — built from the pattern learned from other people's addresses there
 *   mx       — only a common pattern guess; the domain does take mail
 */
export function guess(name, domain, company) {
  const n = splitName(name);
  if (!n || !n.first || !n.last) return null;
  const all = (company?.emails ?? []).map((e) => e.email);
  for (const [p, f] of Object.entries(PATTERNS)) {
    const e = `${f(n)}@${domain}`;
    if (all.includes(e)) return { email: e, confidence: "found", pattern: p, source: company.emails.find((x) => x.email === e)?.url };
  }
  if (company?.pattern) return { email: `${PATTERNS[company.pattern.pattern](n)}@${domain}`, confidence: "pattern", pattern: company.pattern.pattern, examples: company.pattern.examples?.slice(0, 2) };
  if (company?.mx) return { email: `${PATTERNS[PRIOR[0]](n)}@${domain}`, confidence: "mx", pattern: PRIOR[0], alternatives: PRIOR.slice(1, 4).map((p) => `${PATTERNS[p](n)}@${domain}`) };
  return null;
}

/** The person an address belongs to, when their name is on the site (jana.novakova@ ↔ "Jana Nováková"). */
export function ownerOf(email, text) {
  const local = email.split("@")[0].toLowerCase();
  if (email.split("@")[1].split(/[.-]/).some((w) => w.length > 3 && (local.includes(w) || w.includes(local)))) return null;
  for (const full of namesIn(text)) {
    const n = splitName(full);
    if (n && Object.values(PATTERNS).some((f) => f(n) === local) && local.length > 3) return full;
  }
  return null;
}
