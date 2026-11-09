import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import * as timers from "../src/timers.js";

const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "brain-timers-")), "timers.json");
fs.writeFileSync(file, JSON.stringify([
  { id: "85C239FF-0EEF-4664-A893-9A0909AAE4E7", prompt: "Len+pripomeň:+koncept+pre+Malinovú", at: "2026-11-09T07:00:00Z", approved: false, runs: 0 },
  { id: "D3171107-FC88-4362-B22E-4649139A38EB", prompt: "Odošli e-mail Malinovej", at: "2026-11-09T06:59:59Z", approved: true, runs: 0 },
  { id: "AAAA1111-0000-0000-0000-000000000000", prompt: "skontroluj NVDA", at: "2026-11-08T10:00:00Z", every: 900, until: "2026-11-08T12:00:00Z", remind: false },
]));

test("url uses %20, never +, so the app reads the task back exactly", () => {
  const u = timers.url("timer", { q: "a b+c & d", in: 60, from: undefined });
  assert.equal(u, "brain://timer?q=a%20b%2Bc%20%26%20d&in=60");
  assert.ok(!new URL(u).search.includes("+"));
});

test("old + encoded tasks are cleaned, real + kept", () => {
  assert.equal(timers.clean("Odošli+e-mail+z"), "Odošli e-mail z");
  assert.equal(timers.clean("1 + 1"), "1 + 1");
});

test("list is sorted, numbered and readable", () => {
  const l = timers.list(file);
  assert.deepEqual(l.map((j) => j.n), [1, 2, 3]);
  assert.equal(l[0].task, "skontroluj NVDA");
  assert.equal(l[0].every_minutes, 15);
  assert.equal(l[1].mode, "do it (approved)");
  assert.equal(l[2].task, "Len pripomeň: koncept pre Malinovú");
});

test("match by number, id prefix and words", () => {
  const l = timers.list(file);
  assert.equal(timers.match(l, "2")[0].id, "D3171107-FC88-4362-B22E-4649139A38EB");
  assert.equal(timers.match(l, "85c2")[0].n, 3);
  assert.equal(timers.match(l, "malin").length, 2);
  assert.equal(timers.match(l, "odošli malin").length, 1);
  assert.equal(timers.match(l, "nič také").length, 0);
});

test("cancel asks when it is ambiguous or unspecified", async () => {
  assert.ok((await timers.cancel({ which: "malin" }, file)).ambiguous);
  assert.equal((await timers.cancel({}, file)).cancelled.length, 0);
  assert.equal((await timers.cancel({ which: "xyz" }, file)).cancelled.length, 0);
});
