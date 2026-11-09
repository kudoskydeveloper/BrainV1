// LinkedIn messages never go through the linkedin server (it drives Chrome): Brain refuses its message and conversation
// tools and names the Beeper tool to use instead. Needs Brain signed in to Beeper (`brain beeper-login`), else skipped.
import { test } from "node:test";
import assert from "node:assert/strict";
import { call } from "../src/actions.js";
import * as beeper from "../src/beeper.js";

const cases = [
  ["linkedin_propose_message", /messenger_send/],
  ["linkedin_commit_message", /messenger_send/],
  ["linkedin_read_conversation", /messenger_read/],
  ["linkedin_sync_conversations", /messenger_chats/],
  ["linkedin_list_conversations", /messenger_chats/],
];

for (const [tool, want] of cases) {
  test(`linkedin.${tool} goes to Beeper`, { skip: !beeper.connected() && "Beeper not signed in" }, async () => {
    await assert.rejects(call("linkedin", tool, {}), (e) => want.test(e.message) && /network "linkedin"/.test(e.message));
  });
}
