import { test } from "node:test";
import assert from "node:assert/strict";
import { weekOf, sportOf, e1rm, exerciseProgress } from "../src/fitness.js";

test("weekOf gives the Monday of the week", () => {
  assert.equal(weekOf("2026-11-06"), "2026-11-02");        // Friday
  assert.equal(weekOf("2026-11-02 07:30"), "2026-11-02");  // Monday itself
  assert.equal(weekOf("2026-11-08"), "2026-11-02");        // Sunday belongs to the week before
  assert.equal(weekOf("2026-01-01"), "2025-12-29");        // across the year
});

test("sportOf sorts Strava and Hevy types into sports", () => {
  assert.equal(sportOf("WeightTraining"), "strength");
  assert.equal(sportOf("Workout"), "strength");
  assert.equal(sportOf("VirtualRide"), "ride");
  assert.equal(sportOf("Ride"), "ride");
  assert.equal(sportOf("TrailRun"), "run");
  assert.equal(sportOf("Swim"), "swim");
  assert.equal(sportOf("Hike"), "walk");
  assert.equal(sportOf("InlineSkate"), "other");
});

test("e1rm is Epley, a single rep is the weight itself", () => {
  assert.equal(e1rm(100, 1), 100);
  assert.equal(Math.round(e1rm(100, 5) * 10) / 10, 116.7);
  assert.equal(e1rm(0, 10), 0);
});

test("exerciseProgress: top set per workout, warmups ignored, oldest first", () => {
  const w = (start, sets) => ({ title: "Push", start_time: start, exercises: [{ title: "Bench Press (Barbell)", exercise_template_id: "X", sets }] });
  const [bench] = exerciseProgress([
    w("2026-10-17T06:00:00Z", [{ type: "warmup", weight_kg: 60, reps: 20 }, { type: "normal", weight_kg: 100, reps: 5 }]),
    w("2026-10-01T06:00:00Z", [{ type: "normal", weight_kg: 90, reps: 5 }, { type: "normal", weight_kg: 95, reps: 3 }]),
  ], { X: { muscle: "chest" } });
  assert.equal(bench.kind, "weight");
  assert.equal(bench.muscle, "chest");
  assert.equal(bench.sessions, 2);
  assert.deepEqual(bench.history.map((h) => h.top_kg), [95, 100]);
  assert.equal(bench.last.kg, 100);
  assert.equal(bench.best_e1rm_kg, 116.7);
  assert.equal(bench.history[1].volume_kg, 500);   // warmup not counted
  assert.ok(bench.change > 0);
});
