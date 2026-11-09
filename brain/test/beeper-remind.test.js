import assert from "node:assert/strict";
import { test } from "node:test";
import { remindTime } from "../src/beeper.js";

test("reminder time: at (local), minutes, never in the past or over a year", () => {
  const d = remindTime({ minutes: 60 });
  assert.ok(Math.abs(d - Date.now() - 3600000) < 2000);
  const next = new Date(Date.now() + 2 * 86400000);
  const local = `${next.getFullYear()}-${String(next.getMonth() + 1).padStart(2, "0")}-${String(next.getDate()).padStart(2, "0")}T09:00`;
  assert.equal(remindTime({ at: local }).getHours(), 9);
  assert.throws(() => remindTime({ at: "2020-01-01T08:00" }), /past/);
  assert.throws(() => remindTime({ minutes: 400 * 1440 }), /year/);
  assert.throws(() => remindTime({}), /at/);
});
