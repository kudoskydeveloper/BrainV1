// Finding e-mail addresses in a page's HTML: mailto links, plain text, obfuscated forms ("meno [at] firma.sk",
// "meno (zavináč) firma.sk", "meno at firma dot sk") and Cloudflare's e-mail protection (data-cfemail). Pure functions.

const ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", "#64": "@", "#46": "." };

export function decodeEntities(s) {
  return String(s)
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(Number(d)))
    .replace(/&([a-z]+);/gi, (m, n) => ENTITIES[n.toLowerCase()] ?? m);
}

/** Cloudflare "email protection": the address XOR-ed with the first byte, as hex. */
export function decodeCfEmail(hex) {
  const key = parseInt(hex.slice(0, 2), 16);
  let out = "";
  for (let i = 2; i < hex.length; i += 2) out += String.fromCharCode(parseInt(hex.slice(i, i + 2), 16) ^ key);
  return out;
}

/** Visible text of a page (scripts and styles dropped, tags to spaces). */
export function pageText(html) {
  return decodeEntities(
    String(html)
      .replace(/<script[\s\S]*?<\/script>/gi, " ")
      .replace(/<style[\s\S]*?<\/style>/gi, " ")
      .replace(/<!--[\s\S]*?-->/g, " ")
      .replace(/<br\s*\/?>|<\/(p|div|li|tr|h[1-6])>/gi, "\n")
      .replace(/<[^>]+>/g, " "),
  )
    .replace(/[ \t ]+/g, " ")
    .replace(/\n\s*\n+/g, "\n")
    .trim();
}

const EMAIL = /[a-z0-9][a-z0-9._%+-]*@[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}/gi;
// "meno [at] firma.sk", "meno (at) firma [dot] sk", "meno zavináč firma.sk", "meno@firma(dot)sk"
const OBFUSCATED = /([a-z0-9][a-z0-9._%+-]*)\s*(?:\[at\]|\(at\)|\{at\}|\[zavin[aá]č\]|\(zavin[aá]č\)|\s+zavin[aá]č\s+|\s+at\s+)\s*([a-z0-9-]+(?:\s*(?:\.|\[dot\]|\(dot\)|\s+dot\s+|\[bodka\]|\(bodka\))\s*[a-z0-9-]+)+)/gi;
const NOT_EMAIL = /\.(png|jpe?g|gif|svg|webp|avif|css|js)$|@\d+x\.|^[^@]+@(example|domain|email|sentry|wixpress|sentry-next)\.|u00[0-9a-f]{2}/i;

/** Every e-mail address in the HTML, lowercased, with how it was written (mailto, text, obfuscated, cloudflare). */
export function findEmails(html) {
  const out = new Map();
  const add = (e, how) => {
    const email = e.trim().toLowerCase().replace(/^mailto:/, "").replace(/[.,;:]+$/, "");
    if (!email.includes("@") || NOT_EMAIL.test(email) || email.length > 80) return;
    if (!out.has(email)) out.set(email, how);
  };
  for (const m of String(html).matchAll(/data-cfemail="([0-9a-f]+)"/gi)) add(decodeCfEmail(m[1]), "cloudflare");
  for (const m of String(html).matchAll(/\/cdn-cgi\/l\/email-protection#([0-9a-f]+)/gi)) add(decodeCfEmail(m[1]), "cloudflare");
  for (const m of String(html).matchAll(/href=["']mailto:([^"'?]+)/gi)) add(decodeURIComponent(decodeEntities(m[1])), "mailto");
  const text = pageText(html);
  for (const m of text.matchAll(EMAIL)) add(m[0], "text");
  for (const m of text.matchAll(OBFUSCATED)) {
    const domain = m[2].replace(/\s*(?:\[dot\]|\(dot\)|\s+dot\s+|\[bodka\]|\(bodka\))\s*/gi, ".").replace(/\s+/g, "");
    if (/\.[a-z]{2,}$/i.test(domain)) add(`${m[1]}@${domain}`, "obfuscated");
  }
  return [...out].map(([email, how]) => ({ email, how }));
}

const GENERIC = /^(info|office|kontakt|contact|hello|hi|ahoj|mail|email|post|posta|sales|obchod|predaj|prodej|hr|kariera|kariéra|career|careers|jobs|job|praca|prace|nabor|recruit\w*|support|podpora|help|servis|service|faktur\w*|fakturacia|billing|invoice\w*|uctovnictvo|ucetni|accounting|marketing|pr|press|media|admin|webmaster|web|recepcia|recepce|reception|objednavky|orders?|shop|eshop|gdpr|dpo|privacy|legal|noreply|no-reply|newsletter|team|tim|management|vedenie|sekretariat|secretary|booking|rezervacie|rezervace)$/i;

/** A role address (info@, kariera@) rather than a person's. */
export const isGeneric = (email) => GENERIC.test(email.split("@")[0].replace(/[0-9]+$/, ""));

export function linksOf(html, base) {
  const out = [];
  for (const m of String(html).matchAll(/<a\b[^>]*href=["']([^"'#]+)["'][^>]*>([\s\S]*?)<\/a>/gi)) {
    try {
      const u = new URL(decodeEntities(m[1]), base);
      if (!/^https?:$/.test(u.protocol)) continue;
      out.push({ url: u.href.replace(/#.*$/, ""), text: pageText(m[2]).slice(0, 80) });
    } catch {}
  }
  return out;
}

// ── Enrichment: phones, social profiles, company IDs and people with their roles ──────────────────────────────────────

/** Phone numbers: tel: links and SK/CZ numbers written with +421/+420 (or 00…), plus SK mobiles (09xx xxx xxx). E.164-ish. */
export function findPhones(html, { country } = {}) {
  const out = new Map();
  const add = (raw, how) => {
    let d = String(raw).replace(/[^\d+]/g, "").replace(/^00/, "+");
    if (!d.startsWith("+")) {
      if (d.startsWith("0") && country === "CZ") return;   // CZ numbers have no leading 0
      if (d.startsWith("0")) d = "+421" + d.slice(1);
      else if (d.length === 9 && country === "CZ") d = "+420" + d;
      else return;
    }
    if (!/^\+(421|420)\d{8,9}$/.test(d) && !/^\+\d{10,14}$/.test(d)) return;
    if (!out.has(d)) out.set(d, { phone: d, raw: String(raw).trim(), how });
  };
  for (const m of String(html).matchAll(/href=["']tel:([^"']+)/gi)) add(decodeURIComponent(m[1]), "tel");
  const text = pageText(html);
  for (const m of text.matchAll(/(?<![\d+])(?:\+|00)\s?(?:421|420)[\s\/.-]?\(?0?\)?\s?\d{2,3}(?:[\s\/.-]?\d{2,3}){2,3}(?!\d)/g)) add(m[0].replace(/\(0\)/, ""), "text");
  for (const m of text.matchAll(/(?<![\d+\/])09\d{2}[\s\/.-]?\d{3}[\s\/.-]?\d{3}(?![\d\/])/g)) add(m[0], "text");
  return [...out.values()];
}

const SOCIAL = [
  ["linkedin", /^https?:\/\/([a-z]{2,3}\.)?linkedin\.com\/(company|school|showcase)\/[^/?#]+/i],
  ["linkedinPerson", /^https?:\/\/([a-z]{2,3}\.)?linkedin\.com\/in\/[^/?#]+/i],
  ["facebook", /^https?:\/\/(www\.|m\.)?(facebook|fb)\.com\/(?!sharer|share|dialog|plugins|tr\b)[^/?#]+/i],
  ["instagram", /^https?:\/\/(www\.)?instagram\.com\/(?!p\/|explore|share)[^/?#]+/i],
  ["x", /^https?:\/\/(www\.)?(twitter|x)\.com\/(?!intent|share|home)[^/?#]+/i],
  ["youtube", /^https?:\/\/(www\.)?youtube\.com\/(@[^/?#]+|channel\/[^/?#]+|c\/[^/?#]+|user\/[^/?#]+)/i],
];

/** Social profiles linked from the page (share buttons dropped). linkedinPerson = a person's profile URL, never opened. */
export function findSocials(html, base) {
  const out = [];
  for (const { url, text } of linksOf(html, base ?? "https://x.invalid/")) {
    for (const [kind, re] of SOCIAL) {
      const m = url.match(re);
      if (m && !out.some((s) => s.url === m[0].replace(/\/$/, ""))) out.push({ kind, url: m[0].replace(/\/$/, ""), text: text || undefined });
    }
  }
  return out;
}

/** IČO, DIČ and IČ DPH as written on the page (imprint, footer, GDPR page). Counts help pick the company's own. */
export function findIds(text) {
  const t = String(text);
  const all = (re) => [...t.matchAll(re)].map((m) => m[1].replace(/\s+/g, "").toUpperCase());
  return {
    ico: all(/I[ČC]O?\s*[:.]?\s*(\d{2}\s?\d{3}\s?\d{3})(?!\d)/gi).concat(all(/(?:^|[\s(])I[ČC]\s*[:.]\s*(\d{8})(?!\d)/gi)),
    dic: all(/DI[ČC]\s*[:.]?\s*((?:CZ)?\d{8,10})(?!\d)/gi),
    vat: all(/(?:I[ČC]\s*DPH|VAT(?:\s*ID)?)\s*[:.]?\s*((?:SK|CZ)\s?\d{8,10})(?!\d)/gi),
  };
}

// Roles in SK, CZ and English, roughly ordered by seniority within each group
const ROLE = new RegExp(String.raw`(?<![\p{L}])(` + [
  "konate[lľ](?:ka)?", "jednatel(?:ka)?", "majite[lľ](?:ka)?", "majitel(?:ka)?", "owner", "spolu-?zakladate[lľ](?:ka)?", "zakladate[lľ](?:ka)?",
  "spoluzakladatel(?:ka)?", "zakladatel(?:ka)?", "co-?founder", "founder", "predseda(?: predstavenstva| dozornej rady)?", "předseda(?: představenstva)?",
  "[čc]len(?:ka)? predstavenstva", "[čc]len(?:ka)? představenstva", "prokurist(?:a|ka)", "managing director", "managing partner", "partner(?:ka)?",
  "CEO", "CTO", "CFO", "COO", "CMO", "CPO", "CIO", "CHRO", "CRO", "chief [\\p{L} ]{3,30}? officer",
  "gener[aá]ln[yíý] riadite[lľ](?:ka)?", "gener[aá]ln[íi] ředitel(?:ka)?", "riadite[lľ](?:ka)?(?: [\\p{L}]+)?", "ředitel(?:ka)?(?: [\\p{L}]+)?",
  "director(?: of [\\p{L} ]{3,30})?", "[\\p{L}]+ director", "head of [\\p{L} &]{3,30}", "vp(?: of)? [\\p{L} ]{3,30}", "vice president",
  "vedúc[iaa](?: [\\p{L}]+)?", "vedouc[íi](?: [\\p{L}]+)?", "mana[žz][eé]r(?:ka)?(?: [\\p{L}]+)?", "[\\p{L}]+ mana[žz][eé]r(?:ka)?", "[\\p{L}]+ manager", "manager",
  "obchodn[ýáíi] (?:riadite[lľ]|ředitel|z[aá]stupca|z[aá]stupce|mana[žz]er|konzultant)(?:ka)?", "account (?:manager|executive)", "sales(?: [\\p{L}]+)?",
  "marketing(?: [\\p{L}]+)?", "projektov[ýá] mana[žz][eé]r(?:ka)?", "konzultant(?:ka)?", "špecialist(?:a|ka)", "specialist(?:a|ka)?", "asistent(?:ka)?",
  "účtovn[íi]k|účtovn[ií]čka|účetní", "developer", "dizajn[eé]r(?:ka)?", "designer",
].join("|") + String.raw`)(?![\p{L}])`, "iu");

/** Seniority from a role: owner, c-level, director, manager or staff. */
export function seniority(role) {
  const r = fold(role);
  if (/konatel|jednatel|majitel|owner|zakladatel|founder|predseda|clen predstavenstva|prokurist|managing (director|partner)|^partner/.test(r)) return "owner";
  if (/\bc[etfomprhi]o\b|chief .* officer|generaln/.test(r)) return "c-level";
  if (/riaditel|reditel|director|head of|vp |vice president/.test(r)) return "director";
  if (/manazer|manazer|manager|veduc|vedouc/.test(r)) return "manager";
  return "staff";
}
const fold = (s) => String(s ?? "").normalize("NFD").replace(/\p{Diacritic}/gu, "").toLowerCase();

// two capitalised words that are not a person (headings, places, products)
const NOT_NAME = /^(Ochrana|Osobn|Obchodn|Všeobecn|Kontakt|Kontakty|Naše|Náš|Nase|Nas|Náš|O|Our|About|Meet|The|Slovensk|Česk|Česká|Ceska|Spoločnosť|Spolecnost|Bratislava|Praha|Košice|Brno|Žilina|Nitra|Prešov|Trnava|Banská|Ostrava|Plzeň|Olomouc|Copyright|Cookies|Privacy|Terms|Viac|Více|Zobraziť|Read|Learn|Customer|Business|Sales|Marketing|Head|Chief|Managing|Account|Project|Product|General|Senior|Junior|Team|Tím|Tim|Vedenie|Vedení|Board|Our|Kancelária|Pobočka|Sídlo|Studio|Studios|Napíšte|Napiste|Kontaktujte|Zavolajte|Objednajte|Prihláste|Získajte|Pozrite|Chcete|Potrebujete|Fakturačné|Hlavná|Hlavní|Dátum|Datum|Ing|Mgr|Bc)$/;

/** People named next to a role on the page: "Ing. Jana Nováková – konateľka", "Peter Kováč\nHead of Sales". */
export function peopleIn(text) {
  const lines = String(text).split("\n").map((l) => l.trim()).filter(Boolean);
  const out = new Map();
  const name = /(?<!\p{L})((?:(?:Ing|Mgr|Bc|MUDr|JUDr|PhDr|RNDr|doc|prof|Dr)\.\s*)*)(\p{Lu}\p{Ll}+(?:-\p{Lu}\p{Ll}+)?)\s+(\p{Lu}\p{Ll}+(?:-\p{Lu}\p{Ll}+)?)(?!\p{L})/gu;
  for (let i = 0; i < lines.length; i++) {
    for (const m of lines[i].matchAll(name)) {
      if (NOT_NAME.test(m[2]) || NOT_NAME.test(m[3])) continue;
      const after = lines[i].slice(m.index + m[0].length);
      const before = lines[i].slice(0, m.index);
      // the role: after the name on its line, the line below (cards), or just before it on the line ("CEO Jana Nováková")
      const cands = [after, lines[i + 1] && lines[i + 1].length < 90 ? lines[i + 1] : "", before.length < 60 ? before : "", lines[i - 1] && lines[i - 1].length < 60 && lines[i].length < 60 ? lines[i - 1] : ""];
      for (const c of cands) {
        // the role leads a short segment ("Head of Sales", "konateľka spoločnosti"), not a word inside a sentence
        const seg = c.split(/\s[–—|•·]\s|[,;|•·(]|\s-\s/).map((x) => x.trim()).find((x) => x.length < 45 && (x.match(ROLE)?.index ?? 99) <= 12);
        if (!seg) continue;
        const role = seg.replace(/^[-–—:\s]+|[-–—:\s.]+$/g, "");
        if (/\p{Lu}\p{Ll}+\s+\p{Lu}\p{Ll}+/u.test(role.replace(ROLE, ""))) continue;   // another person's name in the segment
        const full = `${m[2]} ${m[3]}`;
        if (!out.has(full)) out.set(full, { name: full, title: m[1].trim() || undefined, role, seniority: seniority(role), line: lines[i].slice(0, 160) });
        break;
      }
    }
  }
  return [...out.values()];
}
