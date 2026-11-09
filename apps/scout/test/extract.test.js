import { test } from "node:test";
import assert from "node:assert/strict";
import { decodeCfEmail, findEmails, isGeneric } from "../src/extract.js";
import { robotsRules } from "../src/crawl.js";
import { guess, learn, splitName } from "../src/pattern.js";

test("finds mailto, plain, obfuscated and Cloudflare addresses", () => {
  // Cloudflare: key 0x42 XOR "a@b.sk"
  const cf = "42" + [..."a@b.sk"].map((c) => (c.charCodeAt(0) ^ 0x42).toString(16).padStart(2, "0")).join("");
  const html = `<a href="mailto:Jana.Novak@Firma.sk">Napíšte</a> info@firma.sk <p>peter [at] firma [dot] sk</p>
    <p>eva (zavináč) firma.sk</p><span data-cfemail="${cf}">[email protected]</span><img src="logo@2x.png">`;
  const got = findEmails(html).map((e) => e.email).sort();
  assert.deepEqual(got, ["a@b.sk", "eva@firma.sk", "info@firma.sk", "jana.novak@firma.sk", "peter@firma.sk"]);
  assert.equal(decodeCfEmail(cf), "a@b.sk");
});

test("role addresses are generic, people's are not", () => {
  assert.ok(isGeneric("info@firma.sk") && isGeneric("kariera@firma.sk") && isGeneric("faktury@firma.sk"));
  assert.ok(!isGeneric("jana.novak@firma.sk"));
});

test("robots.txt rules for * and ScoutBot", () => {
  assert.deepEqual(robotsRules("User-agent: Googlebot\nDisallow: /g\n\nUser-agent: *\nDisallow: /admin\nDisallow:\n"), ["/admin"]);
});

test("learns first.last from names on the page and builds a colleague's address", () => {
  const p = learn(["jana.novakova@firma.sk", "info@firma.sk"], "Tím: Ing. Jana Nováková, riaditeľka. Peter Kováč, obchod.");
  assert.equal(p.pattern, "first.last");
  assert.deepEqual(splitName("Ing. Peter Kováč, PhD."), { first: "peter", last: "kovac" });
  const g = guess("Peter Kováč", "firma.sk", { emails: [{ email: "jana.novakova@firma.sk" }], pattern: p, mx: ["mx"] });
  assert.equal(g.email, "peter.kovac@firma.sk");
  assert.equal(g.confidence, "pattern");
});
