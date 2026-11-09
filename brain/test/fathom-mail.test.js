import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { parseRecap } from "../src/fathom-mail.js";
import { toSlovak } from "../src/translate.js";
import { p } from "../src/paths.js";

const TEXT = " \r\n\n     Meeting Purpose\r\n\r\nFinalize terms.\r\n\r\nKey Takeaways\r\n\r\n  - Equity Offer: 10% each.\r\n\n" +
  "                                 Get your own FREE AI Meeting Assistant \r\n\n" +
  "                                        Meeting with Eva Malá\r\n\n                                  Kudosky Sync\r\n\n" +
  "                                  October 05, 2026   &bull;  \r\n                                  42 mins   &bull;  \r\n                                   View Meeting \r\n\n" +
  "                            Action Items ✨\r\n\n                                          Email GLS HR contact re: status     \r\n\n" +
  "                                        Kudosky\r\n\n                                          Send invite for Oct 8     \r\n\n" +
  "                                        Eva Malá\r\n\n                                  Meeting Summary ✨\r\n\n   Meeting Purpose \r\n";

test("parseRecap reads Courier's plain text of a Fathom recap", () => {
  const r = parseRecap(TEXT, "2026-10-05T14:46:38Z", "https://fathom.video/share/x");
  assert.equal(r.title, "Kudosky Sync");
  assert.equal(r.with, "Eva Malá");
  assert.equal(r.date, "2026-10-05");
  assert.equal(r.minutes, "42");
  assert.deepEqual(r.actions, [{ task: "Email GLS HR contact re: status", assignee: "Kudosky" }, { task: "Send invite for Oct 8", assignee: "Eva Malá" }]);
  assert.match(r.summary, /^Meeting Purpose\n\nFinalize terms\.\n\nKey Takeaways\n\n  - Equity Offer: 10% each\.$/);
});

test("toSlovak translates always, caches each piece and reuses items without the summary", async () => {
  const cache = p("translations.json");
  const saved = fs.existsSync(cache) ? fs.readFileSync(cache) : null;
  try {
    const calls = [];
    const run = async (input) => { calls.push(input); return JSON.stringify({ summary: input.summary && `SK ${input.summary}`, items: input.items.map((t) => `SK ${t}`) }); };
    const tag = `t${Date.now()}`;
    const a = await toSlovak({ summary: "", items: [`Uz po slovensky ${tag}`] }, { run });
    assert.deepEqual(a, { summary: "", items: [`SK Uz po slovensky ${tag}`] });
    const b = await toSlovak({ summary: `Hi ${tag}`, items: [`Uz po slovensky ${tag}`] }, { run });
    assert.deepEqual(b, { summary: `SK Hi ${tag}`, items: [`SK Uz po slovensky ${tag}`] });
    assert.deepEqual(calls[1], { summary: `Hi ${tag}`, items: [] });   // the item came from the cache
    await assert.rejects(toSlovak({ summary: `x ${tag}`, items: [] }, { run: async () => "nope" }));
  } finally { saved ? fs.writeFileSync(cache, saved) : fs.rmSync(cache, { force: true }); }
});
