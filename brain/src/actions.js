// Anything that changes something goes through a proposal: Brain shows exactly what will happen, confirm() runs it.
import { execFile } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { findTool } from "./catalog.js";
import { NEVER, NOT_ROUTED } from "./registry.js";
import { HOME, ICLOUD, p } from "./paths.js";
import { callTool, resultText } from "./pool.js";
import { appendLine, config, readJSON, writeJSON } from "./store.js";
import * as learn from "./learn.js";
import { prettyPath } from "./find.js";
import * as calendar from "./calendar.js";
import * as reminders from "./reminders.js";
import * as idoklad from "./idoklad.js";
import { isFinance, logTrade } from "./market.js";
import * as beeper from "./beeper.js";
import { guardAction, label } from "./map.js";
import * as hevy from "./hevy.js";
import * as strava from "./strava.js";
import * as apple from "./apple.js";

const run = promisify(execFile);
const PROPOSALS = p("proposals.json");
const AUDIT = p("audit.jsonl");
const TTL = 15 * 60000;

export const expand = (f) => path.resolve(String(f).replace(/^~(?=\/|$)/, HOME).replace(/^iCloud Drive(?=\/|$)/, ICLOUD)
  .replace(/^Google Drive \(([^)]+)\)(?=\/|$)/, (_, acct) => path.join(HOME, "Library/CloudStorage", `GoogleDrive-${acct}`)));
const pretty = (f) => prettyPath(f);

function autoConfirmed(server, tool) {
  const list = config().auto_confirm;
  return list.includes(`${server}:${tool}`) || list.includes(`${server}:*`);
}

function propose(action, summary) {
  const all = readJSON(PROPOSALS, {});
  for (const [k, v] of Object.entries(all)) if (Date.now() - v.t > TTL) delete all[k];
  const id = "brain_" + crypto.randomBytes(4).toString("hex");
  all[id] = { t: Date.now(), action, summary };
  writeJSON(PROPOSALS, all);
  return { needs_confirm: true, proposal_id: id, summary,
           next: "Show this summary to the user. Call confirm with the proposal_id only after they say yes. Expires in 15 minutes." };
}

// ---- proxied MCP calls -------------------------------------------------------------------------

// Money (Alpaca and other trading servers): an order, cancel or anything else that changes the account always waits for Brain's
// confirm. auto_confirm and the commit_* pass-through don't apply; only a non-trading setting like the watchlist may be auto-confirmed.
const TRADE = /order|trade|position|exercise|transfer|withdraw|deposit|liquidat|close|fund|journal|wire|ach/i;
export function needsConfirm(server, t) {
  if (t.kind === "read") return false;
  if (isFinance(server)) return t.kind === "commit" || TRADE.test(t.name) || !autoConfirmed(server, t.name);
  return t.kind === "write" && !autoConfirmed(server, t.name);
}

// LinkedIn messages go through Beeper (messenger_chats / read / send with network linkedin), reading as well as sending: the
// linkedin server does both by driving LinkedIn in Chrome, and two clients on the same inbox clash. That server stays for
// people search, connections, tags, project stages and invites.
const VIA_BEEPER = { linkedin: /message|conversation/i };
const BEEPER_FOR = (tool) => /propose|commit|send/i.test(tool) ? 'messenger_send with network "linkedin"'
  : /read/i.test(tool) ? 'messenger_read with network "linkedin"' : 'messenger_chats (or messenger_search) with network "linkedin"';

/** What the user sees on the confirm card: one line in words (the model's summary, else the app and the action), then the
 *  arguments as short readable lines (lists counted and grouped), never a raw JSON call. */
export function callSummary(server, tool, args = {}, summary) {
  const app = label(`mcp:${server}`);
  const head = summary?.trim() ? `${app}: ${summary.trim()}` : `${app}: ${tool.replace(/[_-]+/g, " ").replace(/^./, (c) => c.toUpperCase())}`;
  const short = (v) => { const t = typeof v === "string" ? v : JSON.stringify(v); return t.length > 90 ? t.slice(0, 89) + "…" : t; };
  const lines = [];
  for (const [k, v] of Object.entries(args || {})) {
    if (v == null || v === "") continue;
    if (Array.isArray(v) && v.length && v.every((x) => x && typeof x === "object")) {
      // a list of items: how many, and how they split by a date-like or status field when they have one
      const by = ["date", "due", "dueString", "due_date", "when", "status", "project", "list"].find((f) => v.every((x) => f in x));
      if (by) {
        const n = {};
        for (const x of v) n[x[by]] = (n[x[by]] || 0) + 1;
        lines.push(`${k}: ${v.length} (${Object.entries(n).map(([a, c]) => `${a} ×${c}`).join(", ")})`);
      } else lines.push(`${k}: ${v.length} položiek`);
      const names = v.map((x) => x.content || x.title || x.name || x.subject).filter(Boolean);
      if (names.length) lines.push(`  ${short(names.slice(0, 6).join(", ") + (names.length > 6 ? ` … +${names.length - 6}` : ""))}`);
    } else if (Array.isArray(v)) lines.push(`${k}: ${v.length > 6 ? `${v.length} (${short(v.slice(0, 6).join(", "))} …)` : short(v.join(", "))}`);
    else lines.push(`${k}: ${short(v)}`);
  }
  return [head, ...lines.slice(0, 8).map((l) => l.startsWith("  ") ? l : `· ${l}`)].join("\n");
}

export async function call(server, tool, args = {}, summary) {
  if (VIA_BEEPER[server]?.test(tool) && beeper.connected())
    throw new Error(`LinkedIn messages are read and sent through Beeper, never through the browser: use ${BEEPER_FOR(tool)} (not ${server}.${tool}).`);
  if (NEVER.test(server)) throw new Error(`${server} is never used: e-mail goes through Courier (call courier.*), calendar events through calendar_create / calendar_update / calendar_delete (Apple Calendar).`);
  if (NOT_ROUTED[server]) throw new Error(NOT_ROUTED[server]);
  const t = findTool(server, tool);
  if (!t) throw new Error(`${server}.${tool} not found. Use capabilities to look it up (run scan_now if the server is new).`);
  if (needsConfirm(server, t)) {
    const what = isFinance(server) ? `💸 ${server} (peniaze/obchod, len po tvojom áno): ` : "";
    return propose({ type: "call", server, tool, args }, `${what}${callSummary(server, tool, args, summary)}`);
  }
  const r = await execCall(server, tool, args);
  return isFinance(server) ? stagedCommit(server, tool, r) ?? r : r;
}

/** A trading server's own step 1 (propose_order …) drafted something: turn its step 2 into a Brain proposal right away,
 *  with the server's own summary, so the user confirms once and in Brain. */
function stagedCommit(server, tool, r) {
  if (r.isError || !/^propose/i.test(tool)) return null;
  const commit = findTool(server, tool.replace(/^propose/i, "commit")) || findTool(server, "commit_order");   // propose_exit / propose_replace → commit_order
  let j; try { j = JSON.parse(r.text); } catch { return null; }
  if (!commit || !j?.proposal_id) return null;
  return propose({ type: "call", server, tool: commit.name, args: { proposal_id: j.proposal_id } },
    `💸 ${j.summary || `${server}.${commit.name} ${j.proposal_id}`}\nZadá sa až po tvojom áno.`);
}

async function execCall(server, tool, args) {
  const r = await callTool(server, tool, args);
  appendLine(AUDIT, { server, tool, args, error: !!r.isError });
  // every trade goes into the trading plan's journal (Denník); the model then updates the plan's other sections
  if (isFinance(server) && /^(commit|cancel)/i.test(tool) && !r.isError) {
    let j; try { j = JSON.parse(resultText(r)); } catch { j = {}; }
    const o = j.order || {};
    logTrade(j.placed ? `${j.placed} → ${o.status || "odoslané"}${o.id ? ` (${String(o.id).slice(0, 8)})` : ""}`
      : j.changed ? `${j.changed} → ${o.status || "zmenené"}` : j.cancelled ? `zrušená objednávka ${String(j.cancelled).slice(0, 8)}`
      : `${server}.${tool} ${JSON.stringify(args).slice(0, 200)}`);
  }
  return { server, tool, isError: !!r.isError, text: resultText(r).slice(0, 60000) };
}

// ---- file actions ------------------------------------------------------------------------------

/** Several file actions (a cleanup) as one proposal: steps [{action move|rename|mkdir|trash|tag, paths, destination, new_name, tag}],
 *  each checked like file_action; on confirm they run in order and stop at the first error, reporting what was done. */
export async function cleanupPlan({ title = "Upratanie", steps = [] }) {
  if (!steps.length) throw new Error("no steps");
  if (steps.some((s) => ["open", "reveal", "untag"].includes(s.action))) throw new Error("cleanup steps: move, rename, mkdir, trash, tag");
  const planned = [], lines = [];
  for (const s of steps) {
    const p = await fileAction(s);   // validates and gives the summary; its own proposal is dropped below
    const all = readJSON(PROPOSALS, {}); delete all[p.proposal_id]; writeJSON(PROPOSALS, all);
    planned.push({ type: "file", action: s.action, files: (s.paths || []).map(expand), destination: s.destination && expand(s.destination),
                   new_name: s.new_name, tag: s.tag, tag_color: s.tag_color });
    lines.push(`- ${p.summary}`);
  }
  const trash = steps.filter((s) => s.action === "trash").reduce((n, s) => n + (s.paths || []).length, 0);
  return propose({ type: "file_batch", steps: planned },
    `${title}: ${steps.length} krokov${trash ? `, ${trash} do Koša (obnoviteľné)` : ""}\n${lines.join("\n")}`);
}

async function execBatch(a) {
  const done = [];
  for (const [i, s] of a.steps.entries()) {
    try { done.push(await execFile_(s)); }
    catch (e) { return { done, stopped_at: i + 1, of: a.steps.length, error: e.message }; }
  }
  return { done, all: a.steps.length };
}

const TAG_COLORS = { none: 0, grey: 1, green: 2, purple: 3, blue: 4, yellow: 5, red: 6, orange: 7 };

export async function fileAction({ action, paths = [], destination, new_name, tag, tag_color }) {
  const files = paths.map(expand);
  for (const f of files) if (action !== "mkdir" && !fs.existsSync(f)) throw new Error(`not found: ${pretty(f)}`);
  if (action === "open" || action === "reveal") {   // harmless, runs straight away
    for (const f of files) { await run("open", action === "reveal" ? ["-R", f] : [f]); learn.used(f); }
    return { done: action, paths: files.map(pretty) };
  }
  let summary;
  switch (action) {
    case "move": if (!destination) throw new Error("move needs destination"); summary = `Move ${files.map(pretty).join(", ")} → ${pretty(expand(destination))}`; break;
    case "rename": if (files.length !== 1 || !new_name || new_name.includes("/")) throw new Error("rename needs one path and new_name"); summary = `Rename ${pretty(files[0])} → ${new_name}`; break;
    case "tag": if (!tag) throw new Error("tag needs tag"); summary = `Tag ${files.map(pretty).join(", ")} with "${tag}"`; break;
    case "untag": summary = `Remove all tags from ${files.map(pretty).join(", ")}`; break;
    case "trash": summary = `Move to Trash (recoverable): ${files.map(pretty).join(", ")}`; break;
    case "mkdir": summary = `Create folder ${files.map(pretty).join(", ")}`; break;
    default: throw new Error(`unknown action ${action}`);
  }
  return propose({ type: "file", action, files, destination: destination && expand(destination), new_name, tag, tag_color }, summary);
}

async function execFile_(a) {
  const done = [];
  switch (a.action) {
    case "move":
      fs.mkdirSync(a.destination, { recursive: true });
      for (const f of a.files) {
        const to = path.join(a.destination, path.basename(f));
        if (fs.existsSync(to)) throw new Error(`already exists: ${pretty(to)}`);
        fs.renameSync(f, to); learn.used(f); done.push(pretty(to));
      }
      break;
    case "rename": {
      const to = path.join(path.dirname(a.files[0]), a.new_name);
      if (fs.existsSync(to)) throw new Error(`already exists: ${pretty(to)}`);
      fs.renameSync(a.files[0], to); done.push(pretty(to));
      break;
    }
    case "tag": case "untag": {
      const c = TAG_COLORS[String(a.tag_color || "none").toLowerCase()] ?? 0;
      const xml = `<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array>${a.action === "tag" ? `<string>${a.tag.replace(/[<&]/g, "")}\n${c}</string>` : ""}</array></plist>`;
      const tmp = p("tag.plist");
      fs.writeFileSync(tmp, xml);
      await run("plutil", ["-convert", "binary1", tmp]);
      const hex = fs.readFileSync(tmp).toString("hex");
      for (const f of a.files) { await run("xattr", ["-wx", "com.apple.metadata:_kMDItemUserTags", hex, f]); done.push(pretty(f)); }
      break;
    }
    case "trash": {
      const list = a.files.map((f) => `POSIX file ${JSON.stringify(f)}`).join(", ");
      await run("osascript", ["-e", `tell application "Finder" to delete {${list}}`], { timeout: 60000 });
      done.push(...a.files.map(pretty));
      break;
    }
    case "mkdir":
      for (const f of a.files) { fs.mkdirSync(f, { recursive: true }); done.push(pretty(f)); }
      break;
  }
  appendLine(AUDIT, { file_action: a.action, paths: a.files, destination: a.destination, new_name: a.new_name, tag: a.tag });
  return { done: a.action, paths: done };
}

// ---- WhatsApp: open a chat with the message typed in; optionally press Enter -----------------------

export function whatsappProposal({ name, phone, text, auto_send }) {
  return propose({ type: "whatsapp", phone, text, auto_send: !!auto_send, name },
    `WhatsApp to ${name} (+${phone})${auto_send ? ", sent automatically" : ", opened ready to send (you press Enter)"}:\n"${text}"`);
}

// ---- Messenger (and other Beeper networks): sent through Beeper Desktop's API ----------------------

export function beeperProposal({ id, name, network, text, file }) {
  const att = file ? `\npríloha: ${file.name} (${Math.max(1, Math.round(file.size / 1024))} kB)` : "";
  return propose({ type: "beeper", chatID: id, name, network, text, file }, `${network} to ${name} (cez Beeper, odošle sa po tvojom áno):\n"${text}"${att}`);
}

export function beeperReactProposal({ chatID, messageID, name, network, preview, emoji }) {
  return propose({ type: "beeper_react", chatID, messageID, name, network, emoji }, `${network}: reakcia ${emoji} v chate ${name} na správu:\n${preview}`);
}

export function beeperGroupProposal({ accountID, people, network, title, messageText }) {
  return propose({ type: "beeper_group", accountID, participantIDs: people.map((x) => x.id), network, title, messageText },
    `${network}: nová skupina „${title}“ s ${people.map((x) => x.name).join(", ")}${messageText ? `\nprvá správa: "${messageText}"` : ""}`);
}

export function beeperRenameProposal({ id, name, network, title }) {
  return propose({ type: "beeper_rename", chatID: id, name, network, title }, `${network}: premenovať chat „${name}“ na „${title}“`);
}

async function execBeeper(a) {
  if (a.type === "beeper_group") {
    const r = await beeper.createGroup(a);
    appendLine(AUDIT, { beeper: a.network, group: a.title, people: a.participantIDs.length });
    return { ...r, network: a.network };
  }
  if (a.type === "beeper_rename") {
    const r = await beeper.rename(a);
    appendLine(AUDIT, { beeper: a.network, renamed: a.name, to: a.title });
    return { ...r, network: a.network };
  }
  if (a.type === "beeper_react") {
    const r = await beeper.react(a);
    appendLine(AUDIT, { beeper: a.network, to: a.name, reaction: a.emoji });
    return { to: a.name, network: a.network, ...r, note: "Reaction sent through Beeper." };
  }
  const r = await beeper.send({ chatID: a.chatID, text: a.text, file: a.file });
  appendLine(AUDIT, { beeper: a.network, to: a.name, chars: a.text.length, attachment: a.file?.name, sent: r.sent });
  return { to: a.name, network: a.network, ...r, note: "Sent through Beeper." };
}

async function execWhatsApp(a) {
  await run("open", [`whatsapp://send?phone=${a.phone}&text=${encodeURIComponent(a.text)}`]);
  let sent = false, note = "Opened in WhatsApp with the message typed in. Press Enter there to send.";
  if (a.auto_send) {
    await new Promise((r) => setTimeout(r, 2500));   // let WhatsApp open the chat and fill the box
    try {
      await run("osascript", ["-e", 'tell application "WhatsApp" to activate', "-e", "delay 0.4",
        "-e", 'tell application "System Events" to key code 36'], { timeout: 15000 });
      sent = true; note = "Sent (Enter pressed in WhatsApp).";
    } catch (e) {
      note = "Opened with the message typed in, but couldn't press Enter (Brain needs Accessibility permission). Press Enter in WhatsApp.";
    }
  }
  appendLine(AUDIT, { whatsapp: a.name, phone: a.phone, chars: a.text.length, sent });
  return { to: a.name, sent, note };
}

// ---- calendar: create / update / delete an event (see calendar.js) -------------------------------

export async function calendarProposal(op, args) {
  const plan = await { create: calendar.planCreate, update: calendar.planUpdate, delete: calendar.planDelete }[op](args);
  if (op === "create" && autoConfirmed("brain", "calendar_create")) return calendar.exec(plan.action);
  return propose(plan.action, plan.summary);
}

export async function reminderDeleteProposal(args) {
  const plan = await reminders.planDelete(args);
  return propose(plan.action, plan.summary);
}

export async function hevyProposal(op, args) {
  const plan = await { routine: hevy.planRoutine, workout: hevy.planWorkout, body: hevy.planBody, routine_update: hevy.planRoutineUpdate,
                       workout_update: hevy.planWorkoutUpdate, exercise: hevy.planExercise }[op](args);
  return propose(plan.action, plan.summary);
}

export function stravaProposal(op, args) {
  const plan = op === "update" ? strava.planUpdate(args) : strava.planCreate(args);
  return propose(plan.action, plan.summary);
}

export async function idokladProposal(op, args) {
  const plan = await (op === "invoice" ? idoklad.planInvoice(args) : idoklad.planSend(args));
  return propose(plan.action, plan.summary);
}

export async function appleProposal(op, args) {
  const plan = await (op === "shortcut" ? apple.planShortcut(args) : apple.planAlbumAdd(args));
  if (op === "shortcut" && autoConfirmed("brain", "shortcut_run")) return apple.execShortcut(plan.action);
  return propose(plan.action, plan.summary);
}

export async function confirm(id) {
  const all = readJSON(PROPOSALS, {});
  const prop = all[id];
  delete all[id];
  writeJSON(PROPOSALS, all);
  if (!prop) throw new Error(`no proposal ${id}`);
  if (Date.now() - prop.t > TTL) throw new Error(`${id} expired; ask again`);
  const a = prop.action;
  guardAction(a);   // switched off in the Brain map since it was proposed
  // a timer may carry out what the user approved in advance, but never a trade: those wait for the user's own yes
  if (process.env.BRAIN_TIMER && a.type === "call" && isFinance(a.server)) {
    all[id] = prop; writeJSON(PROPOSALS, all);   // keep it for the user to confirm
    throw new Error("Trades and orders are never placed by a timer: show the proposal and let the user confirm it.");
  }
  return a.type === "call" ? execCall(a.server, a.tool, a.args) : a.type === "whatsapp" ? execWhatsApp(a) : /^beeper/.test(a.type) ? execBeeper(a)
    : a.type === "calendar" ? calendar.exec(a) : a.type === "reminder_delete" ? reminders.execDelete(a)
    : a.type === "shortcut" ? apple.execShortcut(a) : a.type === "photos_album" ? apple.execAlbumAdd(a)
    : a.type === "idoklad" ? idoklad.exec(a) : a.type === "hevy" ? hevy.exec(a) : a.type === "strava" ? strava.exec(a) : a.type === "file_batch" ? execBatch(a) : execFile_(a);
}
