import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { _test } from "../src/apple.js";
import { load } from "../src/health.js";
import * as m from "../src/map.js";

test("Apple tools have their place on the map", () => {
  assert.equal(m.partOf("photos_search"), "photos");
  assert.equal(m.partOf("travel_plan"), "maps");
  assert.equal(m.partOf("shortcut_run"), "shortcuts");
  assert.equal(m.partOf("voice_memo"), "voice_memos");
  assert.equal(m.partOf("safari_history"), "safari");
  assert.equal(m.partOf("health"), "health");
  assert.equal(m.map().nodes.find((n) => n.id === "photos").group, "apple");
});

test("video calls and meeting rooms are not places to travel to", () => {
  for (const l of ["Google Meet (instructions in description)", "https://zoom.us/j/1", "Prague-7-Narnia (16)", "Microsoft Teams Meeting"]) assert.ok(_test.ONLINE.test(l), l);
  for (const l of ["Nová Tržnica, Bratislava", "Einsteinova 18, Bratislava", "Kaviareň Štúr"]) assert.ok(!_test.ONLINE.test(l), l);
});

test("Health Auto Export JSON: days merged, newer export wins, sleep and heart rate read", () => {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), "brain-health-"));
  try {
    const file = (name, metrics, t) => { const f = path.join(d, name); fs.writeFileSync(f, JSON.stringify({ data: { metrics } })); fs.utimesSync(f, t, t); };
    file("a.json", [{ name: "step_count", units: "count", data: [{ date: "2026-11-06 00:00:00 +0100", qty: 1000 }] }], 1000);
    file("b.json", [
      { name: "step_count", units: "count", data: [{ date: "2026-11-06 00:00:00 +0100", qty: 8000 }, { date: "2026-11-07 00:00:00 +0100", qty: 2500.4 }] },
      { name: "sleep_analysis", units: "hr", data: [{ date: "2026-11-07 00:00:00 +0100", totalSleep: 7.25, deep: 1.1, rem: 1.6, core: 4.5, awake: 0.2, sleepStart: "2026-11-06 23:40:00 +0100", sleepEnd: "2026-11-07 07:10:00 +0100" }] },
      { name: "resting_heart_rate", units: "count/min", data: [{ date: "2026-11-07 00:00:00 +0100", qty: 52 }] },
    ], 2000);
    const { days } = load(d);
    assert.equal(days["2026-11-06"].steps, 8000);
    assert.equal(days["2026-11-07"].steps, 2500.4);
    assert.equal(days["2026-11-07"].resting_hr, 52);
    assert.deepEqual(days["2026-11-07"].sleep, { total_h: 7.25, deep_h: 1.1, rem_h: 1.6, core_h: 4.5, awake_h: 0.2, in_bed_h: undefined, from: "23:40", to: "07:10" });
  } finally { fs.rmSync(d, { recursive: true, force: true }); }
});
