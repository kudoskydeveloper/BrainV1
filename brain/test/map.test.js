import assert from "node:assert/strict";
import fs from "node:fs";
import { test } from "node:test";
import { CONFIG } from "../src/paths.js";
import * as m from "../src/map.js";

test("tools belong to their part", () => {
  assert.equal(m.partOf("whatsapp_send"), "whatsapp");
  assert.equal(m.partOf("messenger_remind"), "messenger");
  assert.equal(m.partOf("calendar_events"), "calendar");
  assert.equal(m.partOf("market_overview"), "trading");
  assert.equal(m.partOf("where_is"), "files");
  assert.equal(m.partOf("confirm"), null);
  assert.equal(m.partOf("overview"), null);
});

test("switching a part off refuses its tools, calls and proposals, and on again", () => {
  const before = fs.readFileSync(CONFIG, "utf8");
  try {
    m.set("whatsapp", false);
    m.set(m.serverId("courier"), false);
    assert.throws(() => m.guard("whatsapp_send", {}), /WhatsApp je v Brain mape vypnuté/);
    assert.throws(() => m.guard("call", { server: "courier", tool: "search" }), /Courier/);
    assert.doesNotThrow(() => m.guard("call", { server: "todoist" }));
    assert.doesNotThrow(() => m.guard("calendar_events", {}));
    assert.throws(() => m.guardAction({ type: "whatsapp" }), /WhatsApp/);
    assert.equal(m.map().nodes.find((n) => n.id === "whatsapp").on, false);
    m.set("whatsapp", true);
    assert.doesNotThrow(() => m.guard("whatsapp_send", {}));
  } finally {
    fs.writeFileSync(CONFIG, before);
  }
  assert.equal(fs.readFileSync(CONFIG, "utf8"), before);
});

test("every Brain tool has its own place on the map (a new feature: add it to BUILTIN in src/map.js)", () => {
  const tools = m.toolNames();
  assert.ok(tools.length > 50, "server.js tools were read");
  assert.deepEqual(m.newParts(), [], "tools without a part in map.js BUILTIN (they only show under Nové)");
  assert.equal(m.partOf("notion_search"), "new:notion");   // an unknown tool still lands on the map and can be switched off
});
