import { test } from "node:test";
import assert from "node:assert/strict";
import { parseNote } from "../src/meetings.js";

const NOTE = `# Kudosky vesting

- **When:** 2026-10-27 (46 min)
- **With:** Eva Malá, Ján Vzor <hello@firma2.example>
- **Fathom:** https://fathom.video/share/abc

## Summary

## Meeting Purpose

[Update on the approval.](https://fathom.video/calls/1?t=0)

## Key Takeaways

  - [**Approval Pending:** inspection done.](https://fathom.video/calls/1?t=0)
      - [nested point](https://fathom.video/calls/1?t=1)

## Action items

- [ ] Check the contract — Ján
- [x] Send one-pager

## Transcript

@00:01 A: Hello
@00:02 B: Hi

_Imported by Brain on 2026-11-03._
`;

test("parseNote reads header, sections, depth and action items", () => {
  const n = parseNote(NOTE);
  assert.equal(n.title, "Kudosky vesting");
  assert.equal(n.when, "2026-10-27");
  assert.equal(n.minutes, 46);
  assert.deepEqual(n.people[0], { name: "Eva Malá", email: null });   // the user is left out once dossier.me is set in brain.config.json
  assert.equal(n.fathom, "https://fathom.video/share/abc");
  assert.deepEqual(n.sections.map((s) => s.kind), ["purpose", "takeaways", "action_items"]);
  assert.equal(n.sections[0].items[0].text, "Update on the approval.");
  assert.deepEqual(n.sections[1].items.map((i) => i.depth), [0, 1]);
  assert.equal(n.sections[1].items[0].text, "**Approval Pending:** inspection done.");
  assert.deepEqual(n.sections[2].items.map((i) => i.done), [false, true]);
  assert.equal(n.transcript_lines, 2);
});

test("parseNote reads the Slovak note Brain writes now", () => {
  const n = parseNote("# Sync\n\n- **Kedy:** 2026-11-06 10:00\n- **Účastníci:** Eva Malá <s@x.sk>\n- **Nahraté:** Fathom (Seb), recap e-mail\n\n## Zhrnutie\n\n### Účel stretnutia\n\nZladiť sa.\n\n## Úlohy\n\n- [ ] Poslať ponuku — Kudosky\n\n_Importoval Brain z Fathomu 2026-11-06._\n");
  assert.equal(n.when, "2026-11-06 10:00");
  assert.equal(n.people[0].name, "Eva Malá");
  assert.equal(n.recorded_on, "Fathom (Seb), recap e-mail");
  const tasks = n.sections.find((s) => s.kind === "action_items");
  assert.deepEqual(tasks.items, [{ text: "Poslať ponuku — Kudosky", done: false, depth: 0 }]);
  assert.ok(!JSON.stringify(n.sections).includes("Importoval"));
});
