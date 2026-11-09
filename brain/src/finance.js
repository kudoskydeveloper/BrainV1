// Financie (the personal and business finances app in Hangar, com.lockedin.financie) through its MCP server `financie`:
// the overview for Brain (finance_overview) and a short section of the morning brief (what waits for confirmation and
// what is due today or tomorrow). Everything else (adding a transaction, recurring items, transfers) goes through `call`.
import { callTool, resultText } from "./pool.js";

const eur = (n) => `${n < 0 ? "−" : ""}${Math.abs(n).toLocaleString("sk-SK", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} €`;

/** The app's overview: net worth (personal, business), accounts, this month, what waits, next 14 days, 3 month forecast. */
export async function overview() {
  const r = await callTool("financie", "overview", {});
  const text = resultText(r);
  if (r.isError) throw new Error(text);
  return JSON.parse(text);
}

/** Morning brief lines: late confirmations and what is due today or tomorrow; nothing when all is quiet or the app isn't set up. */
export async function briefSection() {
  let o;
  try { o = await overview(); } catch { return { lines: [], counts: {} }; }
  const today = o.today, tomorrow = new Date(Date.parse(today) + 86400000).toISOString().slice(0, 10);
  const late = o.waiting_confirmation || [];
  const due = (o.next_14_days || []).filter((e) => e.due_date <= tomorrow);
  if (!late.length && !due.length) return { lines: [], counts: { finance_waiting: 0 } };
  const row = (e) => `- ${e.name}: ${eur(e.amount)}${e.late_days ? ` _(${e.late_days} dní, nepotvrdené)_` : e.due_date === today ? " _(dnes)_" : " _(zajtra)_"}`;
  return {
    lines: [`**Financie** · čistý majetok ${eur(o.net_worth)} · [otvoriť](financie://waiting)`, ...late.map(row), ...due.map(row), ""],
    counts: { finance_waiting: late.length },
  };
}
