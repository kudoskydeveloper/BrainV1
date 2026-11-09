// Apple Reminders through the same EventKit helper as the calendar (tools/calendar). Meant for personal things and the
// shopping list (Todoist stays the work task manager). Adding and ticking off run right away (both are easy to undo in
// Reminders); deleting comes back as a proposal. Reminders are never indexed or searched by other tools.
import { helper } from "./calendar.js";
import { fold, recall } from "./notes.js";
import { p } from "./paths.js";
import { appendLine, config } from "./store.js";
import { status } from "./ui.js";

const DEFAULTS = { default_list: "To do", shopping_list: "Shopping", food_topic: "Strava a nákupy" };
const settings = () => ({ ...DEFAULTS, ...(config().reminders || {}) });

export const lists = () => helper(["lists"]);

async function listId(name) {
  const all = await lists();
  const l = all.find((x) => x.id === name || fold(x.title) === fold(name));
  if (!l) throw new Error(`no Reminders list "${name}". Lists: ${all.map((x) => x.title).join(", ")}`);
  return l;
}

export async function list({ list: name, query, done = false } = {}) {
  const args = ["reminders"];
  if (name) args.push("--lists", (await listId(name)).id);
  if (query) args.push("--query", query);
  if (done) args.push("--done");
  status(`Čítam pripomienky${name ? ` v zozname ${name}` : " zo všetkých zoznamov"}${done ? " (hotové za 30 dní)" : ""}`);
  const rs = await helper(args);
  return rs.sort((a, b) => (a.due || "9").localeCompare(b.due || "9") || a.title.localeCompare(b.title));
}

export async function add({ title, list: name, notes, due, priority }) {
  const l = await listId(name || settings().default_list);
  const args = ["add-reminder", "--list", l.id, "--title", title];
  if (notes) args.push("--notes", notes);
  if (due) args.push("--due", due);
  if (priority) args.push("--priority", String({ high: 1, medium: 5, low: 9 }[priority] || priority));
  const r = await helper(args);
  appendLine(p("audit.jsonl"), { reminders: "add", list: l.title, title });
  return r;
}

export async function complete({ id }) {
  const r = await helper(["complete-reminder", "--id", id]);
  appendLine(p("audit.jsonl"), { reminders: "complete", title: r.title });
  return r;
}

export async function planDelete({ id }) {
  const r = (await helper(["reminders"])).concat(await helper(["reminders", "--done"])).find((x) => x.id === id);
  if (!r) throw new Error(`no reminder ${id} (ids come from reminders_list)`);
  return { action: { type: "reminder_delete", id, title: r.title }, summary: `Delete reminder "${r.title}" (${r.list})` };
}

export async function execDelete(a) {
  const r = await helper(["delete-reminder", "--id", a.id]);
  appendLine(p("audit.jsonl"), { reminders: "delete", title: a.title });
  return r;
}

// ---- shopping ----------------------------------------------------------------------------------------------------

/** What's on the shopping list now, plus what the user eats (Brain note), so a fridge photo can be turned into a list. */
export async function shopping() {
  const s = settings();
  const items = await list({ list: s.shopping_list });
  status("Pozerám, čo zvyčajne ješ (poznámka v Braine)");
  const profile = recall(s.food_topic, 1)[0];
  return { list: s.shopping_list, on_list: items.map((r) => ({ id: r.id, title: r.title, ...(r.notes ? { notes: r.notes } : {}) })),
           what_you_eat: profile?.text || "(no food profile yet: ask the user and save it with remember, topic \"" + s.food_topic + "\")",
           how: "For a fridge/pantry photo: compare what you see with what_you_eat, list what is missing or running low, skip what is already on_list, and add items with shopping_add only after the user says yes." };
}

/** What the user usually eats (Brain note), for turning a fridge photo into a shopping list. */
export async function foodProfile() {
  const s = settings();
  const profile = recall(s.food_topic, 1)[0];
  return { what_you_eat: profile?.text || "(no food profile yet: ask the user and save it with remember, topic \"" + s.food_topic + "\")",
           how: "For a fridge/pantry photo: compare what you see with what_you_eat, list what is missing or running low, skip what is already on_list, and add items with shopping_add only after the user says yes." };
}

/** Add several items to the shopping list, skipping ones already there (case and diacritics ignored). */
export async function shoppingAdd({ items }) {
  const s = settings();
  const have = new Set((await list({ list: s.shopping_list })).map((r) => fold(r.title).trim()));
  const added = [], skipped = [];
  for (const it of items) {
    const title = it.trim();
    if (!title || have.has(fold(title))) { skipped.push(title); continue; }
    status(`Pridávam do nákupu: ${title}`);
    await add({ title, list: s.shopping_list });
    have.add(fold(title)); added.push(title);
  }
  return { list: s.shopping_list, added, already_there: skipped };
}
