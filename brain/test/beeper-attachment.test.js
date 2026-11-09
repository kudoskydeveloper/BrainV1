// messenger_send attachments: the file is checked when proposed and must be byte-identical when the send is confirmed.
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import * as beeper from "../src/beeper.js";

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "brain-att-"));
const file = path.join(tmp, "onepager.pdf");
fs.writeFileSync(file, "%PDF-1.4 test");

test("attachmentInfo keeps name, size and hash", () => {
  const a = beeper.attachmentInfo(file);
  assert.equal(a.name, "onepager.pdf");
  assert.equal(a.size, 13);
  assert.match(a.sha256, /^[0-9a-f]{64}$/);
});

test("attachmentInfo refuses a missing file and one over 20 MB", () => {
  assert.throws(() => beeper.attachmentInfo(path.join(tmp, "nope.pdf")), /not found/);
  const big = path.join(tmp, "big.pdf");
  fs.writeFileSync(big, Buffer.alloc(beeper.MAX_ATTACHMENT + 1));
  assert.throws(() => beeper.attachmentInfo(big), /limit is 20 MB/);
});

test("a file changed after approval is not sent", async () => {
  const a = beeper.attachmentInfo(file);
  fs.writeFileSync(file, "%PDF-1.4 changed");
  await assert.rejects(beeper.send({ chatID: "!none:beeper.local", text: "x", file: a }), /changed or disappeared/);
});
