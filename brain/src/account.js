// Which Claude account Brain app asks with (the claude CLI's sign-in), and switching to another one, e.g. when its usage
// limit is used up. Brain only reads the address and plan (claude auth status); the sign-in itself stays with claude
// (in the Keychain) and is never read, printed or stored here. Switching logs out and signs in again in Terminal, where
// the user confirms it, so a question in a chat can't log anyone out by itself.
import { execFile, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { HOME } from "./paths.js";

const run = promisify(execFile);
const CLAUDE = [".npm-global/bin/claude", ".local/bin/claude"].map((f) => path.join(HOME, f)).concat(["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]);
const claude = () => CLAUDE.find((f) => { try { fs.accessSync(f, fs.constants.X_OK); return true; } catch { return false; } });

/** Brain app's environment: without a Claude Code session's variables (CLAUDE_CONFIG_DIR, its host login, ...). */
const env = () => Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith("CLAUDE") && !["AI_AGENT", "BAGGAGE"].includes(k)));

export const validEmail = (s) => (/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(String(s || "").trim()) ? String(s).trim() : null);

/** { logged_in, email, plan, method } of the claude CLI (what Brain app uses); no tokens. */
export async function status() {
  const c = claude();
  if (!c) throw new Error("claude CLI not found");
  const { stdout } = await run(c, ["auth", "status", "--json"], { env: env(), timeout: 30000 }).catch((e) => ({ stdout: e.stdout || "{}" }));
  const j = JSON.parse(stdout || "{}");
  return { logged_in: !!j.loggedIn, email: j.email, plan: j.subscriptionType, method: j.authMethod,
           used_by: "Brain app and claude in Terminal (Claude Desktop and its Code tab have their own sign-in)" };
}

const describe = (s) => (s.logged_in ? `${s.email}${s.plan ? ` (${s.plan})` : ""}` : "nikto (odhlásené)");

/** Opens Terminal: shows the current account, asks, then logs out and signs in with another one (email pre-fills the page). */
export async function switchAccount({ email } = {}) {
  const c = claude();
  if (!c) throw new Error("claude CLI not found");
  if (email && !validEmail(email)) throw new Error(`not an e-mail address: ${email}`);
  const now = await status().catch(() => ({ logged_in: false }));
  const current = describe(now).replace(/[^\p{L}\p{N}@._+()\s-]/gu, "");
  const login = `'${c}' auth login${email ? ` --email '${validEmail(email)}'` : ""}`;
  const f = path.join(os.tmpdir(), "brain-relogin.command");
  fs.writeFileSync(f, [
    "#!/bin/zsh", "unset CLAUDE_CONFIG_DIR",
    `echo "Brain a claude sú prihlásené ako: ${current}"`,
    `read "a?Odhlásiť a prihlásiť sa iným Claude účtom${email ? ` (${validEmail(email)})` : ""}? [a/N] "`,
    `[[ "$a" == [aAyY]* ]] || { echo "Nič som nezmenil."; exit 0; }`,
    `'${c}' auth logout`,
    `${login} && echo && '${c}' auth status --text && echo "\\nHotovo, môžeš zavrieť toto okno a pýtať sa Brainu."`, "",
  ].join("\n"), { mode: 0o755 });
  await run("open", [f]);
  return { opened: "Terminal", current: describe(now), next: "In Terminal: confirm with 'a', then sign in with the other account in the browser (switch the account on claude.ai there if it signs in the old one automatically)." };
}

/** `brain relogin [email]` in Terminal: log out and sign in again right here. */
export async function reloginHere(email) {
  const c = claude();
  if (!c) throw new Error("claude CLI not found");
  if (email && !validEmail(email)) throw new Error(`not an e-mail address: ${email}`);
  const step = (args) => new Promise((ok, no) => spawn(c, args, { env: env(), stdio: "inherit" })
    .on("exit", (code) => (code === 0 ? ok() : no(new Error(`claude ${args.join(" ")} failed (${code})`)))));
  console.log(`Teraz: ${describe(await status())}`);
  await step(["auth", "logout"]);
  await step(["auth", "login", ...(email ? ["--email", validEmail(email)] : [])]);
  return { now: describe(await status()) };
}
