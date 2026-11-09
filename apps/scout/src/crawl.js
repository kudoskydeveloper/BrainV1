// Reading a company website politely: robots.txt first, an honest User-Agent, at most ~15 pages per domain, a pause between
// pages, and only the pages where addresses live (home, contact, team, about, imprint, GDPR). Nothing is submitted anywhere.
import { findEmails, findIds, findPhones, findSocials, linksOf, pageText, peopleIn } from "./extract.js";

export const UA = "ScoutBot/0.1 (personal contact research; respects robots.txt)";
export const MAX_PAGES = 15;
const PAUSE_MS = Number(process.env.SCOUT_PAUSE_MS ?? 1200);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// paths worth a look, in order; links whose URL or text match WORTH are followed too
const PATHS = ["/", "/kontakt", "/kontakty", "/contact", "/contacts", "/kontakt/", "/o-nas", "/about", "/about-us", "/tim", "/nas-tim", "/team",
  "/impressum", "/imprint", "/kariera", "/kariera/", "/career", "/gdpr", "/ochrana-osobnych-udajov", "/ochrana-osobnich-udaju", "/privacy", "/privacy-policy"];
const WORTH = /kontakt|contact|o-nas|o-n[aá]s|about|t[ií]m|team|ludia|lidi|people|impressum|imprint|kari[eé]r|career|gdpr|ochrana|privacy|vedenie|vedeni|management|spolo[cč]nost|firma|company/i;

const FILE = /\.(jpe?g|png|gif|svg|webp|avif|pdf|docx?|xlsx?|zip|mp4|mp3|ico|css|js)$/i;

export function normDomain(input) {
  const s = String(input).trim().toLowerCase();
  try {
    return new URL(/^https?:/.test(s) ? s : `https://${s}`).hostname.replace(/^www\./, "");
  } catch {
    return null;
  }
}

export async function get(url, ms = 15_000) {
  const r = await fetch(url, { headers: { "user-agent": UA, accept: "text/html,text/plain;q=0.9,*/*;q=0.5" }, redirect: "follow", signal: AbortSignal.timeout(ms) });
  const type = r.headers.get("content-type") ?? "";
  const body = /html|text|xml/.test(type) || !type ? await r.text() : "";
  return { status: r.status, url: r.url, body };
}

/** Disallow rules for "*" and for ScoutBot, from robots.txt (missing robots.txt = allowed). */
export function robotsRules(txt) {
  const rules = [];
  let applies = false;
  for (const raw of String(txt).split(/\r?\n/)) {
    const line = raw.replace(/#.*/, "").trim();
    const [k, ...rest] = line.split(":");
    const v = rest.join(":").trim();
    if (/^user-agent$/i.test(k)) applies = v === "*" || /scoutbot/i.test(v);
    else if (applies && /^disallow$/i.test(k) && v) rules.push(v);
  }
  return rules;
}
const allowed = (rules, path) => !rules.some((r) => path.startsWith(r.replace(/\*.*$/, "")));

/** Reads up to MAX_PAGES pages of one domain and returns every address found, with the page it was on. */
export async function crawl(domainInput, { maxPages = MAX_PAGES, log = () => {} } = {}) {
  const domain = normDomain(domainInput);
  if (!domain) throw new Error(`Not a domain: ${domainInput}`);
  let origin = `https://${domain}`;
  let rules = [];
  try {
    const r = await get(`${origin}/robots.txt`, 8000);
    if (r.status === 200) rules = robotsRules(r.body);
  } catch {}
  // the home page first, then the links it has to contact / team / about pages, then the usual paths as a fallback
  const queue = [origin + "/"];
  const fallback = PATHS.slice(1);
  const seen = new Set();
  let linked = 0;
  const bodies = new Set();   // a missing page often returns the home page (soft 404): same content, skipped
  const pages = [];
  const found = new Map();   // email → { email, how, url, context }
  let text = "";
  const country = domain.endsWith(".cz") ? "CZ" : "SK";
  const phones = new Map(), socials = new Map(), people = new Map();
  const ids = { ico: [], dic: [], vat: [] };
  while ((queue.length || fallback.length) && pages.length < maxPages) {
    // the usual paths only when the site's own links led nowhere useful
    if (!queue.length && linked > 0) break;
    const url = queue.length ? queue.shift() : origin + fallback.shift();
    const key = url.replace(/\/$/, "");
    if (seen.has(key)) continue;
    seen.add(key);
    const u = new URL(url);
    if (!allowed(rules, u.pathname)) { pages.push({ url, skipped: "robots.txt" }); continue; }
    let r;
    try {
      r = await get(url);
    } catch (e) {
      if (pages.length === 0 && origin.startsWith("https://") && !origin.includes("www.")) { origin = `https://www.${domain}`; queue.unshift(origin + "/"); }
      pages.push({ url, error: e.cause?.code ?? e.name });
      continue;
    }
    pages.push({ url, status: r.status });
    log(`${r.status} ${url}`);
    if (r.status !== 200 || !r.body) continue;
    const final = new URL(r.url);
    if (normDomain(final.hostname) !== domain && !final.hostname.endsWith(domain)) continue;   // redirected away
    if (final.origin !== origin) { origin = final.origin; }   // firma.sk → www.firma.sk: keep asking there
    seen.add(r.url.replace(/\/$/, ""));
    const sig = r.body.length + ":" + r.body.slice(0, 2000);
    if (bodies.has(sig)) { pages[pages.length - 1].duplicate = true; continue; }
    bodies.add(sig);
    const t = pageText(r.body);
    text += "\n" + t;
    for (const e of findEmails(r.body)) {
      if (found.has(e.email)) continue;
      const i = t.toLowerCase().indexOf(e.email.split("@")[0]);
      found.set(e.email, { ...e, url: r.url, context: i >= 0 ? t.slice(Math.max(0, i - 90), i + 60).replace(/\s+/g, " ") : null });
    }
    for (const p of findPhones(r.body, { country })) if (!phones.has(p.phone)) {
      const i = t.indexOf(p.raw);
      phones.set(p.phone, { ...p, url: r.url, context: i >= 0 ? t.slice(Math.max(0, i - 90), i + 40).replace(/\s+/g, " ") : null });
    }
    for (const so of findSocials(r.body, r.url)) if (!socials.has(so.url)) socials.set(so.url, { ...so, url: so.url, page: r.url });
    for (const p of peopleIn(t)) if (!people.has(p.name)) people.set(p.name, { ...p, url: r.url });
    const id = findIds(t);
    for (const k of Object.keys(ids)) ids[k].push(...id[k]);
    for (const l of linksOf(r.body, r.url)) {
      const h = normDomain(new URL(l.url).hostname);
      if (h === domain && !FILE.test(new URL(l.url).pathname) && (WORTH.test(l.url) || WORTH.test(l.text)) && !seen.has(l.url.replace(/\/$/, "")) && !queue.includes(l.url)) { queue.push(l.url); linked++; }
    }
    if (queue.length && pages.length < maxPages) await sleep(PAUSE_MS);
  }
  return { domain, pages, emails: [...found.values()], phones: [...phones.values()], socials: [...socials.values()], people: [...people.values()], ids, text };
}
