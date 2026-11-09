import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";
import { call } from "../src/actions.js";
import { search } from "../src/catalog.js";
import { addCourier, fromIndex } from "../src/mailmerge.js";
import { loadServers, NEVER, NOT_ROUTED } from "../src/registry.js";

test("index hits (day only) match Courier mails of the same day", () => {
  const idx = fromIndex([{ source: "email", title: "Ponuka — Jana Nová", date: "2026-10-05", where: "email:a/INBOX", excerpt: "…" }]);
  assert.deepEqual(idx[0], { client: "thunderbird", subject: "Ponuka", from: "Jana Nová", date: "2026-10-05", where: "email:a/INBOX", excerpt: "…" });
  const m = addCourier(idx, [{ client: "courier", id: 9, subject: "Re: Ponuka", from: "\"Jana Nová\" <jana@x.sk>", date: "2026-10-05T14:02:00Z" }]);
  assert.equal(m.length, 1);
  assert.equal(m[0].client, "thunderbird+courier");
});

test("Courier hits merge into the mail list", () => {
  const list = [{ client: "thunderbird", subject: "Ponuka", from: "Jana Nová <jana@x.sk>", date: "2026-10-05T12:02:00.000Z", message_id: "a@x" }];
  const m = addCourier(list, [
    { client: "courier", id: 7, subject: "Re: Ponuka", from: "Jana Nová <jana@x.sk>", date: "2026-10-05T12:03:00Z" },
    { client: "courier", id: 8, subject: "Iné", from: "x@y.sk", date: "2026-10-06T08:00:00Z" },
  ]);
  assert.deepEqual(m.map((x) => x.client), ["courier", "thunderbird+courier"]);
  assert.equal(m[1].courier_id, 7);
});

test("Spark is never loaded, listed or called; Thunderbird is not routed (mail only through Courier)", async () => {
  assert.ok(NEVER.test("Spark") && NEVER.test("spark") && !NEVER.test("courier"));
  assert.deepEqual(Object.keys(loadServers()).filter((n) => NEVER.test(n)), []);
  await assert.rejects(call("Spark", "search", {}), /never used: e-mail goes through Courier/);
  await assert.rejects(call("thunderbird-mail", "sendMail", {}), /through Courier/);
  assert.ok(NOT_ROUTED["thunderbird-mail"]);
  assert.deepEqual(search("thunderbird mail send").filter((t) => t.server === "thunderbird-mail" || NEVER.test(t.server)), []);
});

test("Brain's instructions and tools never point to Spark, except the rule that forbids it", () => {
  const files = fs.readdirSync(new URL("../src", import.meta.url)).filter((f) => f.endsWith(".js"))
    .map((f) => [f, fs.readFileSync(new URL(`../src/${f}`, import.meta.url), "utf8")]);
  for (const [f, text] of files) {
    const lines = text.split("\n").filter((l) => /spark(?!les)/i.test(l) && !/never/i.test(l));
    assert.deepEqual(lines, [], `${f} mentions Spark outside a "never" rule`);
  }
  const server = files.find(([f]) => f === "server.js")[1];
  assert.match(server, /e-mail only through Courier/);
  assert.match(server, /Never suggest, use or call Spark/);
});
