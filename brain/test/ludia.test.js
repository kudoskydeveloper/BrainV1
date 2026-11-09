import test from "node:test";
import assert from "node:assert/strict";
import { nameFromEmail, normPhone, tidyName } from "../src/ludia.js";

test("phones end up in one international form", () => {
  assert.equal(normPhone("0902 365 993"), "421902365993");
  assert.equal(normPhone("+420 775 879 916"), "420775879916");
  assert.equal(normPhone("00421 911 501 382"), "421911501382");
  assert.equal(normPhone("112"), "");
});

test("Outlook style names are turned around", () => {
  assert.equal(tidyName("HORVÁTHOVÁ Zuzana"), "Zuzana Horváthová");
  assert.equal(tidyName("Ján Novák"), "Ján Novák");
  assert.equal(tidyName("Ondráš, J. (Jakub)"), "Ondráš, J. (Jakub)");
});

test("a name from an address when nothing else is known", () => {
  assert.equal(nameFromEmail("jan.novak@firma.sk"), "Jan Novak");
  assert.equal(nameFromEmail("obchod@firma.sk"), "");
});
