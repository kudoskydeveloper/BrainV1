// Meeting notes → Slovak. Every Fathom summary and action item goes through the claude CLI (the same sign-in Brain app
// uses), always, even when the text is already Slovak: the model then only tidies it. Translations are cached by input,
// so the same text always gets the same Slovak (a note rewritten later, or the same item seen twice, matches itself).
import { execFile } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { HOME, p } from "./paths.js";
import { readJSON, writeJSON } from "./store.js";

const CACHE = p("translations.json");   // { sha1(input): output }
const MODEL = process.env.BRAIN_TRANSLATE_MODEL || "haiku";
const CLAUDE = [".npm-global/bin/claude", ".local/bin/claude"].map((f) => path.join(HOME, f)).concat(["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]);
const claude = () => CLAUDE.find((f) => { try { fs.accessSync(f, fs.constants.X_OK); return true; } catch { return false; } });
const env = () => Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("CLAUDE") && !["AI_AGENT", "BAGGAGE"].includes(k)));

const SYSTEM = [
  "You translate meeting notes into Slovak. Output only JSON, no prose, no code fence.",
  "Input: {\"summary\": Markdown, \"items\": [strings]}. Output: {\"summary\": Markdown in Slovak, \"items\": [the same number of strings in Slovak, same order]}.",
  "Translate everything into natural Slovak, even text that is already Slovak or mixed (then only fix and unify it).",
  "Keep names of people, companies and products, e-mail addresses, numbers, dates, amounts and links exactly as they are.",
  "Keep the Markdown structure and translate headings too (e.g. Meeting Purpose → Účel stretnutia, Key Takeaways → Kľúčové zistenia, Topics → Témy, Next Steps → Ďalšie kroky); standalone section titles in plain text become '### ' headings. Action items are short imperative tasks (e.g. 'Poslať Davidovi ponuku').",
].join("\n");

const hash = (o) => crypto.createHash("sha1").update(JSON.stringify(o)).digest("hex");

function ask(input) {
  const c = claude();
  if (!c) return Promise.reject(new Error("claude CLI not found"));
  return new Promise((ok, no) => {
    const child = execFile(c, ["-p", "--model", MODEL, "--output-format", "text", "--tools", "", "--strict-mcp-config",
      "--setting-sources", "", "--no-session-persistence", "--system-prompt", SYSTEM],
    { env: env(), timeout: 180000, maxBuffer: 1 << 24 }, (e, stdout, stderr) => (e ? no(new Error(`preklad zlyhal: ${String(stderr || e.message).slice(0, 200)}`)) : ok(stdout)));
    child.stdin.end(JSON.stringify(input));
  });
}

function parse(out, n) {
  const t = String(out).trim().replace(/^```(?:json)?\s*|\s*```$/g, "");
  const j = JSON.parse(t.slice(t.indexOf("{"), t.lastIndexOf("}") + 1));
  if (typeof j.summary !== "string" || !Array.isArray(j.items) || j.items.length !== n) throw new Error("preklad: neočakávaný tvar odpovede");
  return { summary: j.summary.trim(), items: j.items.map((s) => String(s).trim()) };
}

/** { summary, items } in Slovak. Each piece is cached on its own, so an item reads the same whether or not the summary
 *  came with it. Throws if the CLI fails, so the caller can leave the meeting for the next run. */
export async function toSlovak({ summary = "", items = [] }, { run = ask } = {}) {
  const sum = String(summary || ""), its = items.map((s) => String(s || ""));
  const cache = readJSON(CACHE, {});
  const kS = hash(["s", sum]), kI = its.map((t) => hash(["i", t]));
  const want = { summary: sum.trim() && !cache[kS] ? sum : "", items: its.filter((t, i) => t.trim() && !cache[kI[i]]) };
  if (want.summary || want.items.length) {
    let out, err;
    for (let i = 0; i < 2 && !out; i++) { try { out = parse(await run(want), want.items.length); } catch (e) { err = e; } }
    if (!out) throw err;
    if (want.summary) cache[kS] = out.summary;
    want.items.forEach((t, i) => { cache[hash(["i", t])] = out.items[i]; });
    writeJSON(CACHE, cache);
  }
  return { summary: sum.trim() ? cache[kS] : sum, items: its.map((t, i) => (t.trim() ? cache[kI[i]] : t)) };
}
