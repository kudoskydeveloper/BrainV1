import { test } from "node:test";
import assert from "node:assert/strict";
import { guideFor, ownPart } from "../src/style.js";

const GUIDE = "# Ako píše\n\nintro\n\n## Správy – pracovné skupiny a ľudia\n\nchat rules\n\n## Správy – cudzí ľudia\n\nformal chat\n\n## Maily\n\nmail rules\n\n## Z ktorej schránky\n\n- 10T";

test("guideFor picks the chat or the e-mail sections", () => {
  const chat = guideFor("chat", GUIDE), mail = guideFor("email", GUIDE);
  assert.match(chat, /chat rules/); assert.match(chat, /formal chat/); assert.doesNotMatch(chat, /mail rules/);
  assert.match(mail, /mail rules/); assert.match(mail, /- 10T/); assert.doesNotMatch(mail, /chat rules/);
  assert.match(mail, /^# Ako píše/);
});

test("ownPart drops the quoted reply and the signature", () => {
  assert.equal(ownPart("Ahoj Zuzka,\r\nvďaka.\r\n\r\nOn Mon, 3 Nov 2026 Zuzka wrote:\r\n> text"), "Ahoj Zuzka,\nvďaka.");
  assert.equal(ownPart("Dobrý deň,\nposielam.\n-- \n10T\nJán Vzor"), "Dobrý deň,\nposielam.");
});
