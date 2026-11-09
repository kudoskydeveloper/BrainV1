// Your action items from newly imported meetings go straight into Todoist, each one exactly once. The user asked for this
// to be automatic, so it skips the usual confirm step. item.target picks the Todoist account (Kudosky or 10T; private
// meetings go to Apple Reminders "To do"); within it the project is chosen anew every time from the account's current
// projects (pickProject), so a project the user adds later (say "Klient A") is used without any change here.
import crypto from "node:crypto";
import { p } from "./paths.js";
import { callTool, resultText } from "./pool.js";
import * as reminders from "./reminders.js";
import { appendLine, config, readJSON, writeJSON } from "./store.js";

const STATE = p("autotasks.json");   // { added: [hashes] }
// default_project: where items go when no project fits the meeting (Inbox = the account's inbox);
// section: used when the chosen project has a section of that name (never created)
const DEFAULTS = { enabled: true, due: "in 3 days", priority: "p3", personal_list: "To do",
                   todoists: { kudosky: { server: "todoist", default_project: "Inbox", section: "From meetings", label: "" },
                               "10t": { server: "todoist-10t", default_project: "10T Studios", section: "Z meetingov", label: "10T: " } } };
const settings = () => ({ ...DEFAULTS, ...(config().auto_tasks || {}) });
const key = (i) => crypto.createHash("sha1").update(`${i.date}|${i.meeting}|${i.task}`.toLowerCase()).digest("hex").slice(0, 16);
const json = (t) => JSON.parse(t.split("\n")[0]);   // Todoist replies: JSON line, then a text summary

const norm = (t) => String(t || "").normalize("NFD").replace(/\p{M}/gu, "").toLowerCase();
// words in project names that say nothing about a meeting
const GENERIC = new Set(["kudosky", "studios", "tasks", "inbox", "personal", "projekt", "project", "ulohy", "todo"]);

/** What ties a meeting to a project: its whole name, its distinctive words, and anything after "Brain:" in its description (comma-separated). */
export function projectWords(pr) {
  const name = norm(pr.name).replace(/[^\p{L}\p{N}]+/gu, " ").trim();
  const words = name.split(" ").filter((w) => w.length >= 4 && !GENERIC.has(w));
  const extra = ((norm(pr.description).match(/brain:([^\n]*)/) || [])[1] || "").split(",").map((x) => x.trim()).filter(Boolean);
  return [...new Set([name, ...words, ...extra])];
}

/**
 * The project of these that the meeting is about: a word in the meeting's title counts 3, each mention in its
 * attendees/summary 1; at least 3 is needed, so a passing mention or two in the summary isn't enough. Null when none fits. Personal projects
 * and the inbox are never picked this way.
 */
export function pickProject(projects, item) {
  const has = (hay, w) => hay.includes(w) || hay.replace(/\s+/g, "").includes(w.replace(/\s+/g, ""));
  const mentions = (hay, w) => Math.max(hay.split(w).length, hay.replace(/\s+/g, "").split(w.replace(/\s+/g, "")).length) - 1;
  const head = norm(item.meeting), body = norm(item.context);
  let best = null, top = 2;
  for (const pr of projects) {
    if (pr.inboxProject || pr.isArchived || /personal|súkrom|sukrom/i.test(pr.name)) continue;
    const ws = projectWords(pr);
    const score = 3 * ws.filter((w) => has(head, w)).length + ws.reduce((n, w) => n + mentions(body, w), 0);
    if (score > top) { best = pr; top = score; }
  }
  return best;
}

async function toTodoist(server, projectId, sectionName, items, s) {
  const secs = json(resultText(await callTool(server, "find-sections", { projectId }))).sections || [];
  const sectionId = secs.find((x) => x.name === sectionName)?.id;
  const tasks = items.map((i) => ({
    content: i.task, projectId, sectionId, priority: s.priority, dueString: s.due,
    description: `From the ${i.date} meeting "${i.meeting}" (${i.folder || "Kudosky Drive/9. Meetings"}).${i.note ? " " + i.note : ""}`,
  }));
  const r = await callTool(server, "add-tasks", { tasks });
  if (r.isError) throw new Error(resultText(r).slice(0, 300));
  return tasks.map((t) => t.content);
}

/** Items of one Todoist account, each into the project its meeting is about (or the default one). */
async function toAccount(t, items, s) {
  const projects = json(resultText(await callTool(t.server, "find-projects", {}))).projects || [];
  const fallback = projects.find((x) => x.name === t.default_project || (t.default_project === "Inbox" && x.inboxProject));
  if (!fallback) throw new Error(`no "${t.default_project}" project in ${t.server}`);
  const groups = new Map();
  for (const i of items) {
    const pr = pickProject(projects, i) || fallback;
    groups.set(pr, [...(groups.get(pr) || []), i]);
  }
  const added = [];
  for (const [pr, list] of groups) added.push(...(await toTodoist(t.server, pr.id, t.section, list, s)).map((x) => `${t.label}${pr.name}: ${x}`));
  return added;
}

/** items: [{ date, meeting, task, target?, context?, folder?, note? }] (context: attendees and summary, for picking the project) — only the user's own items. Returns what was added. */
export async function addMeetingTasks(items) {
  const s = settings();
  if (!s.enabled || !items?.length) return { added: 0 };
  const state = readJSON(STATE, { added: [] });
  const fresh = items.filter((i) => !state.added.includes(key(i))).slice(0, 25);
  if (!fresh.length) return { added: 0 };

  const by = (t) => fresh.filter((i) => (i.target || "kudosky") === t);
  const added = [], done = [];
  for (const [target, t] of Object.entries(s.todoists)) {
    if (!by(target).length) continue;
    added.push(...await toAccount(t, by(target), s)); done.push(...by(target));
  }
  for (const i of by("personal")) {
    await reminders.add({ title: i.task, list: s.personal_list, notes: `Z meetingu ${i.date} „${i.meeting}“.` });
    added.push(`Pripomienky: ${i.task}`); done.push(i);
  }
  state.added.push(...done.map(key));
  state.added = state.added.slice(-3000);
  writeJSON(STATE, state);
  appendLine(p("audit.jsonl"), { auto_tasks: added, reason: "auto_tasks enabled (user asked for automatic meeting tasks)" });
  return { added: added.length, tasks: added };
}

/** Mark items as already handled without adding them (used once so old meetings don't flood Todoist). */
export function markHandled(items) {
  const state = readJSON(STATE, { added: [] });
  state.added.push(...items.map(key));
  writeJSON(STATE, state);
}
