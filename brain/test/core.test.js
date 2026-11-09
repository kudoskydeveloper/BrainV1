import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { kind } from "../src/catalog.js";
import * as notes from "../src/notes.js";
import * as learn from "../src/learn.js";
import * as actions from "../src/actions.js";

test("read/write/commit classification", () => {
  assert.equal(kind({ name: "daktela_read" }), "read");
  assert.equal(kind({ name: "linkedin_propose_message" }), "read");
  assert.equal(kind({ name: "linkedin_commit_message" }), "commit");
  assert.equal(kind({ name: "commit_order" }), "commit");
  assert.equal(kind({ name: "update_watchlist" }), "write");
  assert.equal(kind({ name: "deleteMessages" }), "write");
  assert.equal(kind({ name: "searchMessages" }), "read");
  assert.equal(kind({ name: "anything", annotations: { readOnlyHint: true } }), "read");
});

test("remember replaces the same topic, recall and forget", () => {
  const topic = "test-topic-" + Date.now();
  const a = notes.remember({ text: "Bramble deck is in Projects/Bramble", topic });
  const b = notes.remember({ text: "Bramble deck moved to Archive", topic });
  assert.deepEqual(b.replaced, [a.id]);
  assert.match(notes.recall(topic)[0].text, /Archive/);
  assert.equal(notes.forget({ id: b.id }).length, 1);
  assert.equal(notes.recall(topic).filter((n) => n.topic === topic).length, 0);
});

test("opening a search result links it to the query", () => {
  const id = Date.now(), f = "/tmp/brain-learn-" + id, q = `quarterly invoice brain-test-${id}`;
  learn.searched(q, [f]);
  learn.used(f);
  assert.deepEqual(learn.linksFor(q), [f]);
});

test("file actions propose first, confirm runs, proposals are single use", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "brain-"));
  const target = path.join(dir, "new folder");
  const prop = await actions.fileAction({ action: "mkdir", paths: [target] });
  assert.equal(prop.needs_confirm, true);
  assert.equal(fs.existsSync(target), false);
  await actions.confirm(prop.proposal_id);
  assert.equal(fs.existsSync(target), true);
  await assert.rejects(actions.confirm(prop.proposal_id), /no proposal/);
  const ren = await actions.fileAction({ action: "rename", paths: [target], new_name: "renamed" });
  await actions.confirm(ren.proposal_id);
  assert.equal(fs.existsSync(path.join(dir, "renamed")), true);
});

test("trading servers: orders, cancels and commits always wait for Brain's confirm", () => {
  const w = (name, k = "write") => ({ name, kind: k });
  assert.equal(actions.needsConfirm("market-alerts", w("commit_order", "commit")), true);
  assert.equal(actions.needsConfirm("market-alerts", w("cancel_order")), true);
  assert.equal(actions.needsConfirm("alpaca", w("place_stock_order")), true);
  assert.equal(actions.needsConfirm("alpaca", w("close_all_positions")), true);
  assert.equal(actions.needsConfirm("market-alerts", w("propose_order", "read")), false);   // only drafts; Brain wraps its commit
  assert.equal(actions.needsConfirm("market-alerts", w("quote", "read")), false);
  assert.equal(actions.needsConfirm("market-alerts", w("update_watchlist")), false);   // auto_confirm in brain.config.json, not a trade
  assert.equal(actions.needsConfirm("linkedin", w("linkedin_commit_message", "commit")), false);   // other servers' own two-step flow
});

test("positions without a working stop loss", async () => {
  const { unprotected } = await import("../src/market.js");
  const pos = [{ symbol: "AAPL", qty: "10" }, { symbol: "SPY", qty: "2" }, { symbol: "TSLA", qty: "-5" }, { symbol: "MSFT", qty: "4" }];
  const orders = [
    { symbol: "SPY", side: "buy", type: "limit", status: "filled", order_class: "bracket",   // filled entry, its legs still working
      legs: [{ symbol: "SPY", side: "sell", type: "limit", status: "new", qty: "2", time_in_force: "gtc" },
             { symbol: "SPY", side: "sell", type: "stop", status: "held", qty: "2", time_in_force: "gtc", stop_price: "740" }] },
    { symbol: "TSLA", side: "buy", type: "trailing_stop", status: "new", qty: "5", time_in_force: "gtc" },
    { symbol: "MSFT", side: "sell", type: "stop", status: "new", qty: "4", time_in_force: "day", stop_price: "480" },   // lapses tonight
    { symbol: "AAPL", side: "sell", type: "stop", status: "expired", qty: "10", time_in_force: "day" },   // already lapsed
  ];
  assert.deepEqual(unprotected(pos, orders), [{ symbol: "AAPL", qty: 10, covered: 0, day: 0, stops: [] },
    { symbol: "MSFT", qty: 4, covered: 4, day: 4, stops: ["480"] }]);
});

test("market brief lines", async () => {
  const { lines } = await import("../src/market.js");
  const L = lines({ paper: true, account: { equity: 101000, cash: 50000, pl_today: 1000 }, alert_pct: 3,
    positions: [{ symbol: "AAPL", qty: "10", unrealized_pl: "12.5", unrealized_plpc: "0.012" }],
    quotes: [{ symbol: "NVDA", last: 200, pct: -4.2 }, { symbol: "SPY", last: 700, pct: 0.3 }] });
  assert.match(L[0], /Účet \(paper\): 101[\s ]000,00 USD · dnes \+1[\s ]000,00 \(\+1,00 %\)/);
  assert.match(L[1], /AAPL 10 ks \+12,50 \(\+1,2 %\)/);
  assert.match(L[2], /\*\*NVDA 200,00 −4,2 %\*\* · SPY 700,00 \+0,3 %/);
});

test("meeting tasks go to the Todoist project the meeting is about", async () => {
  const { pickProject } = await import("../src/autotasks.js");
  const projects = [{ id: "i", name: "Inbox", inboxProject: true }, { id: "n", name: "Kudosky × netWRK - Tasks" },
    { id: "u", name: "Klient A" }, { id: "v", name: "Firma B" }, { id: "c", name: "Coworking Mesto", description: "Brain: cmesto, coworking mesto" },
    { id: "p", name: "Personal" }];
  const pick = (meeting, context = "") => pickProject(projects, { meeting, context })?.id ?? null;
  assert.equal(pick("KLIENT A weekly"), "u");
  assert.equal(pick("Weekly", "We agreed with klienta to send the deck. Klient A wants pricing."), "u");
  assert.equal(pick("firma b – rozvrhy"), "v");
  assert.equal(pick("Call", "cmesto pricing, cmesto lease, cmesto"), "c");
  assert.equal(pick("netWRK sync"), "n");
  assert.equal(pick("Intro", "Kudosky demo, one mention of netWRK"), null);
  assert.equal(pick("Personal stuff"), null);
});
