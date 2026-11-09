#!/usr/bin/env node
// brain scan | brain where <query> | brain search <query> | brain tools [query] | brain idoklad-login | brain fathom
// brain strava-setup / strava-login: connect Strava (your API application from strava.com/settings/api, then sign in)
// brain hevy-key: save the Hevy API key from the clipboard (hevy.com/settings?developer, Hevy Pro)
// brain connect <name>: sign in to a remote MCP server (OAuth in the browser), e.g. brain connect hevy
// brain beeper-login: connect Brain to Beeper Desktop (Messenger, Instagram, …); approve it in Beeper
// brain messenger-ocr: read the text in Messenger photos and PDFs not read yet (through Beeper)
// brain whatsapp-ocr: read the text in all WhatsApp photos not read yet (the daily scan does up to 300)
// brain fitness [--days 30]: Hevy + Strava + MyFitnessPal overview as JSON (the Fitness app reads this)
// brain meetings [--days 90]: Fathom notes (parsed) + upcoming meetings as JSON; brain meeting-prep <event id> (the Meetingy app)
// brain ludia: people overview as JSON (the Ľudia app); ludia-person <id>; ludia-set <id> '<json>'; ludia-merge <id> <other>; ludia-split <id>; ludia-sources '<json>'
// brain account | brain relogin [e-mail]: which Claude account Brain app uses; log in with another one
import { whereIs } from "./find.js";
import * as catalog from "./catalog.js";
import { closeAll } from "./pool.js";
import { scanAll } from "./scan.js";
import { searchEverywhere } from "./search.js";
import { morningBrief } from "./brief.js";
import { ensureDirs } from "./store.js";
import * as idoklad from "./idoklad.js";
import * as fathom from "./fathom.js";
import { addMeetingTasks } from "./autotasks.js";
import { buildIndex } from "./semantic.js";
import * as account from "./account.js";
import * as wa from "./whatsapp.js";
import * as beeper from "./beeper.js";
import * as crm from "./crm.js";
import * as oauth from "./oauth.js";
import * as hevy from "./hevy.js";
import * as strava from "./strava.js";
import * as fitness from "./fitness.js";
import * as meetings from "./meetings.js";
import * as ludia from "./ludia.js";
import { config } from "./store.js";

/** New Fathom recordings from both accounts → notes, your action items → Todoist/Reminders, notes → search. Run every 30 min by Brain app. */
async function fathomQuick() {
  const r = await fathom.importNew();
  const tasks = r.action_items.length ? await addMeetingTasks(r.action_items).catch((e) => ({ error: e.message })) : { added: 0 };
  if (r.written.length) await buildIndex({ only: "files" }).catch(() => {});
  return { new_meetings: r.written, accounts: r.accounts, tasks };
}

/** brain strava-setup: the Client ID and Secret of your Strava API application, typed in Terminal. */
async function stravaSetup() {
  const { createInterface } = await import("node:readline/promises");
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const id = (await rl.question("Strava Client ID: ")).trim(), secret = (await rl.question("Strava Client Secret: ")).trim();
  rl.close();
  return strava.saveApp(id, secret);
}

/** brain connect <name>: sign in to a remote MCP server listed in brain.config.json "remote" (e.g. hevy). */
async function connectRemote(name) {
  const url = config().remote?.[name];
  if (!url) return `unknown remote server "${name}"; add it to brain.config.json "remote": { "${name}": "<https url>" }`;
  const r = await oauth.connect(name, url);
  await catalog.refresh().catch(() => {});
  return r;
}

ensureDirs();
const [cmd, ...rest] = process.argv.slice(2);
const q = rest.join(" ");
const out = cmd === "scan" ? await scanAll()
  : cmd === "where" ? await whereIs(q)
  : cmd === "search" ? await searchEverywhere(q)
  : cmd === "brief" ? (await morningBrief({ mark: !rest.includes("--peek") }).then((b) => rest.includes("--json") ? b : b.markdown))
  : cmd === "idoklad-login" ? await idoklad.login()
  : cmd === "fathom" ? await fathomQuick()
  : cmd === "beeper-login" ? await beeper.login()
  : cmd === "linkedin-inbox" ? await beeper.linkedinInbox()
  : cmd === "crm" ? await crm.overview()
  : cmd === "crm-account" ? await crm.account(rest[0], rest.slice(1).join(" "))
  : cmd === "crm-do" ? await crm.act(rest[0], rest[1], JSON.parse(rest.slice(2).join(" ") || "{}"))
  : cmd === "connect" ? await connectRemote(rest[0])
  : cmd === "hevy-key" ? await hevy.saveKeyFromClipboard()
  : cmd === "strava-setup" ? await stravaSetup()
  : cmd === "strava-login" ? await strava.login()
  : cmd === "messenger-ocr" ? await beeper.ocrRecent({ max: 100000 })
  : cmd === "whatsapp-ocr" ? await wa.ocrImages({ max: 100000 })
  : cmd === "fitness" ? await fitness.overview({ days: Number(rest[rest.indexOf("--days") + 1]) || 30 })
  : cmd === "meetings" ? await meetings.overview({ days: Number(rest[rest.indexOf("--days") + 1]) || 90 })
  : cmd === "meeting-prep" ? await meetings.prep({ id: rest[0] })
  : cmd === "meeting-move" ? meetings.move({ file: rest[0], to: rest[1] })
  : cmd === "meeting-delete" ? meetings.remove({ file: rest[0] })
  : cmd === "ludia" ? await ludia.overview()
  : cmd === "ludia-person" ? await ludia.person({ id: rest.join(" ") })
  : cmd === "ludia-set" ? await ludia.update({ id: rest[0], ...JSON.parse(rest.slice(1).join(" ") || "{}") })
  : cmd === "ludia-merge" ? await ludia.merge({ id: rest[0], other: rest[1] })
  : cmd === "ludia-split" ? await ludia.split({ id: rest[0] })
  : cmd === "ludia-search" ? await ludia.search({ query: q })
  : cmd === "ludia-crm-tools" ? ludia.crmTools()
  : cmd === "ludia-sources" ? ludia.setSources(JSON.parse(q || "{}"))
  : cmd === "account" ? await account.status()
  : cmd === "relogin" ? await account.reloginHere(rest[0])
  : cmd === "tools" ? catalog.search(q).map((t) => `${t.kind.padEnd(6)} ${t.server}.${t.name}`)
  : "usage: brain scan | brief [--json] [--peek] | where <query> | search <query> | tools [query] | idoklad-login | fathom | whatsapp-ocr | beeper-login | linkedin-inbox | crm | crm-account <10t|kudosky> <account> | crm-do <10t|kudosky> <action> <json> | messenger-ocr | fitness [--days N] | meetings [--days N] | meeting-prep <id> | meeting-move <path> <10t|kudosky|personal|other> | meeting-delete <path> | ludia | ludia-person <id> | ludia-set <id> <json> | ludia-merge <id> <other id> | ludia-split <id> | ludia-search <topic> | ludia-crm-tools | ludia-sources <json> | account | relogin [e-mail]";
// write and wait until it's flushed: process.exit right after console.log cuts long output to a pipe (the apps read through one)
await new Promise((done) => process.stdout.write((typeof out === "string" ? out : JSON.stringify(out, null, 1)) + "\n", done));
await closeAll();
process.exit(0);
