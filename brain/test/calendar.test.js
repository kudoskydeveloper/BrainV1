import assert from "node:assert/strict";
import { test } from "node:test";
import { repeatPlan } from "../src/calendar.js";
import * as m from "../src/map.js";

test("calendar_create (also with repeat) stays in the Kalendár part of the map", () => {
  assert.equal(m.partOf("calendar_create"), "calendar");
});

test("repeat: weekly on Monday and Thursday, no end", () => {
  const r = repeatPlan({ freq: "weekly", days: ["th", "mo"] }, "2026-11-09T06:00", "2026-11-09T07:30");   // 9. 11. 2026 is a Monday
  assert.deepEqual(r.args, ["--repeat", "weekly", "--interval", "1", "--days", "mo,th"]);
  assert.equal(r.start, "2026-11-09T06:00");
  assert.equal(r.moved, false);
  assert.equal(r.text, "každý týždeň v po a št, bez konca");
});

test("repeat: a start on another day moves forward to the first chosen day, end with it", () => {
  const r = repeatPlan({ freq: "weekly", days: ["fr"] }, "2026-11-17T06:00", "2026-11-17T07:30");   // Tuesday → Friday 20. 11.
  assert.equal(r.start, "2026-11-20T06:00");
  assert.equal(r.end, "2026-11-20T07:30");
  assert.equal(r.moved, true);
  assert.equal(r.text, "každý týždeň v pi, bez konca");
});

test("repeat: interval, until and count", () => {
  assert.equal(repeatPlan({ freq: "weekly", interval: 2, days: ["tu", "fr", "we"], until: "2026-12-31" }, "2026-11-10T06:00").text, "každé 2 týždne v ut, st a pi, do 2026-12-31");
  assert.deepEqual(repeatPlan({ freq: "daily", count: 10 }, "2026-11-10T06:00").args, ["--repeat", "daily", "--interval", "1", "--count", "10"]);
  assert.equal(repeatPlan({ freq: "monthly", interval: 6 }, "2026-11-10").text, "každých 6 mesiacov, bez konca");
  assert.equal(repeatPlan({ freq: "yearly" }, "2026-11-10").text, "každý rok, bez konca");
  assert.equal(repeatPlan(undefined, "2026-11-10"), null);
});

test("repeat: wrong input is refused", () => {
  assert.throws(() => repeatPlan({ freq: "hourly" }, "2026-11-10T06:00"), /freq/);
  assert.throws(() => repeatPlan({ freq: "daily", days: ["mo"] }, "2026-11-10T06:00"), /only go with freq weekly/);
  assert.throws(() => repeatPlan({ freq: "weekly", days: ["xx"] }, "2026-11-10T06:00"), /unknown day/);
  assert.throws(() => repeatPlan({ freq: "weekly", until: "2026-12-31", count: 3 }, "2026-11-10T06:00"), /not both/);
  assert.throws(() => repeatPlan({ freq: "weekly", until: "31.12.2026" }, "2026-11-10T06:00"), /YYYY-MM-DD/);
  assert.throws(() => repeatPlan({ freq: "weekly", until: "2026-11-01" }, "2026-11-10T06:00"), /before the start/);
  assert.throws(() => repeatPlan({ freq: "weekly", interval: 0 }, "2026-11-10T06:00"), /interval/);
});
