// Merging e-mail hits from the old Thunderbird history (its local index and MCP search) with Courier's, the user's mail app.
// Read-only. A mail found in both is matched by Message-ID, else by sender, subject without Re:/Fwd: and time (±3 minutes).
// Spark is never used (the user's only mail client is Courier).
import { fold } from "./notes.js";

const address = (from = "") => (from.match(/<([^>]*)>?/)?.[1] || from).toLowerCase().replace(/…$/, "");
const name = (from = "") => fold(from.replace(/<.*$/, "").replace(/["\\]/g, "")).trim();   // the index keeps only the name
const prefix = (a, b) => !!a && !!b && (a.startsWith(b) || b.startsWith(a));   // a client may cut long values
const subjectKey = (s = "") => fold(s).replace(/^((re|fwd?|aw|wg|odp|sv)\s*:\s*)+/g, "").replace(/…$/, "").replace(/\s+/g, " ").trim();
/** Some clients print local time without a zone, Thunderbird ISO in UTC. */
const time = (d = "") => new Date(/T.*(Z|[+-]\d\d:?\d\d)$/.test(d) ? d : d.replace(" ", "T")).getTime();

function same(a, b) {
  if (a.message_id && b.message_id) return a.message_id === b.message_id;
  const sender = prefix(address(a.from), address(b.from)) || prefix(name(a.from), name(b.from));
  if (!sender || !prefix(subjectKey(a.subject), subjectKey(b.subject))) return false;
  const day = (d) => String(d).slice(0, 10);   // the search-by-meaning index keeps only the day
  return String(a.date).length <= 10 || String(b.date).length <= 10 ? day(a.date) === day(b.date) : Math.abs(time(a.date) - time(b.date)) <= 3 * 60000;
}

/** Hits of textSearch/semanticSearch on the e-mail index (Thunderbird's mbox files) in the same shape as Courier's. */
export function fromIndex(hits) {
  if (!Array.isArray(hits)) return [];
  return hits.map(({ source, title, ...h }) => {
    const i = title.lastIndexOf(" — ");
    return { client: "thunderbird", subject: i < 0 ? title : title.slice(0, i), from: i < 0 ? "" : title.slice(i + 3), ...h };
  });
}

/** Courier hits added to a merged list: a mail already there gets "+courier" and courier_id, others are appended. */
export function addCourier(list = [], courier = []) {
  const out = list.map((m) => ({ ...m }));
  for (const c of courier) {
    const t = out.find((m) => !String(m.client).includes("courier") && same(m, c));
    if (t) Object.assign(t, { client: `${t.client}+courier`, courier_id: c.id, account: t.account || c.account, excerpt: t.excerpt || c.excerpt });
    else out.push(c);
  }
  return out.sort((a, b) => (time(b.date) || 0) - (time(a.date) || 0));
}
