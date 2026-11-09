// The CRM app's data (`brain crm`, `brain crm-account <business> <account>`): the two business CRMs side by side, read
// through their own MCP servers, so the app never needs the web apps.
//   10T     — 10T Base, MCP `weare10t-chat` (stdio bridge to weare10t.com/mcp)
//   Kudosky — Kuboard, MCP `kuboard` (remote, OAuth: `brain connect kuboard`)
// Everything is normalised to one shape per business: stages, deals, accounts, tasks (and Kuboard's leads). An account's
// detail adds what Brain knows around it: mail in Courier (by domain and contact e-mails) and invoices in Faktúry (by IČO).
import { p } from "./paths.js";
import { callTool, resultText } from "./pool.js";
import { appendLine } from "./store.js";

const TEN_T = "weare10t-chat";
const KUBOARD = "kuboard";

async function json(server, tool, args = {}) {
  const r = await callTool(server, tool, args, 90_000);
  const t = resultText(r);
  if (r.isError) throw new Error(t.slice(0, 300));
  try {
    return JSON.parse(t);
  } catch {
    throw new Error(`${server}.${tool} returned text, not JSON: ${t.slice(0, 160)}`);
  }
}

const host = (u) => {
  try {
    return new URL(/^https?:/.test(u) ? u : `https://${u}`).hostname.replace(/^www\./, "");
  } catch {
    return null;
  }
};
const cents = (c) => (c == null ? null : Math.round(c) / 100);

// ---- 10T Base ----

async function tenT() {
  const [stages, deals, accounts, tasks] = await Promise.all([
    json(TEN_T, "list_pipeline_stages"),
    json(TEN_T, "list_deals", { limit: 100 }),
    json(TEN_T, "list_accounts", { limit: 100 }),
    json(TEN_T, "list_tasks", { limit: 100 }),
  ]);
  const byId = Object.fromEntries(accounts.map((a) => [a.id, a]));
  return {
    id: "10t",
    name: "10T",
    stages: stages.map((s) => ({ key: s.key, label: s.label, kind: s.kind })),
    deals: deals.map((d) => ({
      id: d.id, ref: d.ref, title: d.title, stage: d.stage, value: d.value ?? null, mrr: null, currency: d.currency ?? "EUR",
      probability: d.probability ?? null, accountId: d.accountId, account: byId[d.accountId]?.name ?? String(d.account ?? "").replace(/^A-\w+ /, ""),
      nextStep: d.nextStep ?? null, nextStepOn: d.nextStepOn ?? null, expectedCloseOn: d.expectedCloseOn ?? null,
      closedAt: d.wonAt ?? d.lostAt ?? null, kinds: d.kinds ?? [],
    })),
    accounts: accounts.filter((a) => !a.is_own).map((a) => ({ id: a.id, ref: a.ref, name: a.name, lifecycle: a.lifecycle, website: a.website, domain: a.website ? host(a.website) : null, updatedAt: a.updated_at })),
    tasks: tasks.map((t) => ({ id: t.id, title: t.title, due: t.due_on, accountId: t.account_id, dealId: t.deal_id, projectId: t.project_id })),
    leads: [],
  };
}

// ---- Kuboard ----

async function kuboard() {
  const [board, leads, tasks, found] = await Promise.all([
    json(KUBOARD, "deal_list", { limit: 200 }),
    json(KUBOARD, "lead_list", { limit: 200 }).catch(() => []),
    json(KUBOARD, "task_list", { owner: "all", due: "any", limit: 200 }).catch(() => []),
    json(KUBOARD, "account_search", { query: "A-", limit: 50 }).catch(() => []),   // every ref starts with A-
  ]);
  const stageKey = Object.fromEntries(board.stages.map((s) => [s.id, s.key]));
  const accounts = Array.isArray(found) ? found : found.accounts ?? found.items ?? [];
  return {
    id: "kudosky",
    name: "Kudosky",
    stages: board.stages.sort((a, b) => a.position - b.position).map((s) => ({ key: s.key, label: s.label, kind: s.is_won ? "won" : s.is_lost ? "lost" : "open", probability: s.probability })),
    deals: board.deals.map((d) => ({
      id: d.id, ref: d.ref, title: d.title, stage: d.stage ?? stageKey[d.stage_id], value: cents(d.one_off_cents) || null, mrr: cents(d.mrr_cents),
      currency: d.currency ?? "EUR", seats: d.seats ?? null, probability: null, accountId: d.account_id, account: d.account?.name ?? "",
      nextStep: null, nextStepOn: null, expectedCloseOn: d.expected_close_on ?? null, closedAt: d.closed_at ?? null, kinds: [],
    })),
    accounts: accounts.map((a) => ({ id: a.id, ref: a.ref, name: a.name, lifecycle: a.lifecycle ?? a.lead_status ?? null, website: a.website ?? null, domain: a.website ? host(a.website) : null, updatedAt: a.updated_at ?? null })),
    tasks: (Array.isArray(tasks) ? tasks : tasks.tasks ?? []).map((t) => ({ id: t.id, title: t.title, due: t.due_on ?? t.dueOn ?? null, accountId: t.account_id ?? null, dealId: t.deal_id ?? null })),
    leads: (Array.isArray(leads) ? leads : []).map((l) => ({
      id: l.id, ref: l.ref, name: l.name, website: l.website, source: l.source, status: l.lead_status, overdue: !!l.overdue,
      nextTask: l.nextTask ? { title: l.nextTask.title, due: l.nextTask.due_on ?? l.nextTask.dueOn ?? null } : null,
      contact: l.contact ? { name: `${l.contact.first_name ?? ""} ${l.contact.last_name ?? ""}`.trim(), position: l.contact.position, email: l.contact.email, phone: l.contact.phone } : null,
      createdAt: l.created_at, lastTouchAt: l.lastTouchAt,
    })),
  };
}

/** Both CRMs. One that doesn't answer comes back with its error and the other still loads. */
export async function overview() {
  const load = async (name, f) => {
    try {
      return { ok: true, ...(await f()) };
    } catch (e) {
      return { ok: false, id: name, name: name === "10t" ? "10T" : "Kudosky", error: e.message, stages: [], deals: [], accounts: [], tasks: [], leads: [] };
    }
  };
  const businesses = await Promise.all([load("10t", tenT), load("kudosky", kuboard)]);
  return { generatedAt: new Date().toISOString(), businesses };
}

// ---- one account, with what's around it ----

/** Mail in Courier with the account's domain or a contact's address: the newest conversations. */
async function courierMail(domain, emails) {
  const queries = [...new Set([domain, ...emails].filter(Boolean))].slice(0, 4);
  const out = new Map();
  for (const q of queries) {
    try {
      const r = await json("courier", "search", { query: q, limit: 15 });
      for (const m of Array.isArray(r) ? r : r.results ?? r.messages ?? []) {
        const key = m.thread_id ?? m.id;
        if (!out.has(key)) out.set(key, { id: m.id, threadId: m.thread_id, date: m.date, subject: m.subject, from: m.from, snippet: m.snippet, account: m.account, folder: m.folder, unread: !!m.unread });
      }
    } catch {}
  }
  return [...out.values()].sort((a, b) => String(b.date).localeCompare(String(a.date))).slice(0, 20);
}

/** Invoices in Faktúry for this IČO (10T's invoicing). */
async function invoices(registrationNos) {
  const ico = registrationNos.filter(Boolean);
  if (!ico.length) return [];
  try {
    const r = await json("faktury", "invoice_list", { client: ico[0], status: "all", limit: 50 });
    return Array.isArray(r) ? r : r.invoices ?? r.items ?? [];
  } catch {
    return [];
  }
}

/** Kudosky's invoices live in Kuboard (its MCP reads them since invoice_list; empty until that's deployed). */
async function kuboardInvoices(accountId) {
  try {
    const r = await json(KUBOARD, "invoice_list", { account: accountId, limit: 50 });
    return (Array.isArray(r) ? r : []).map((i) => ({
      number: i.number, status: i.status, total: cents(i.total_cents), currency: i.currency, issue_date: i.issued_at?.slice(0, 10) ?? null,
      due_date: i.due_at, client: i.account?.name, period: i.period_start && i.period_end ? `${i.period_start} – ${i.period_end}` : null, pdf: i.external_pdf_url ?? null,
    }));
  } catch {
    return [];
  }
}

/** A won 10T deal → an invoice draft in Faktúry, issued by 10T Studios, for the client's billing entity (by IČO the rest comes
 *  from the business register), one line with the deal's title and value. Only a draft: you check it and issue it in Faktúry,
 *  which opens on it. */
export async function invoiceDraft({ deal, account: acc }) {
  const d = await json(TEN_T, "get_deal", { deal });
  const deal_ = d.deal ?? d;
  const a = await json(TEN_T, "get_account", { account: acc ?? deal_.accountId ?? deal_.account_id });
  const co = (a.companies ?? []).find((c) => c.is_primary) ?? a.companies?.[0];
  if (!co?.registration_no && !co?.legal_name) throw new Error(`${a.account.name} has no billing details (IČO) in 10T Base; add them first.`);
  const issuers = await json("faktury", "accounts", {});
  const issuer = (Array.isArray(issuers) ? issuers : []).find((x) => /10T/i.test(x.name));
  if (!issuer) throw new Error("No 10T company in Faktúry.");
  const value = Number(deal_.value ?? 0);
  if (!(value > 0)) throw new Error(`The deal ${deal_.ref ?? deal} has no value to invoice.`);
  const client = { name: co.legal_name ?? a.account.legal_name ?? a.account.name, ...(co.registration_no ? { ico: co.registration_no } : {}),
    ...(co.tax_id ? { dic: co.tax_id } : {}), ...(co.vat_id ? { ic_dph: co.vat_id } : {}), ...(co.billing_email ? { email: co.billing_email } : {}) };
  const draft = await json("faktury", "invoice_draft", {
    company: String(issuer.id), client,
    items: [{ description: deal_.title, quantity: 1, unit: "paušál", unit_price: value }],
    internal_note: `Z CRM: obchod ${deal_.ref ?? ""} (${a.account.ref} ${a.account.name})`,
  });
  const id = draft.id ?? draft.invoice?.id;
  appendLine(p("crm-audit.jsonl"), { at: new Date().toISOString(), business: "10t", action: "invoice_draft", deal: deal_.ref, draft: id, ok: true });
  if (id) await callTool("faktury", "open_in_app", { id }).catch(() => {});
  return { ok: true, draftId: id, client: client.name, total: value };
}

export async function account(business, ref) {
  if (business === "10t") {
    const a = await json(TEN_T, "get_account", { account: ref });
    const domain = a.account?.website ? host(a.account.website) : null;
    const emails = (a.contacts ?? []).map((c) => c.email).filter(Boolean);
    const [mail, inv] = await Promise.all([courierMail(domain, emails), invoices((a.companies ?? []).map((c) => c.registration_no))]);
    return {
      business, id: a.account.id, ref: a.account.ref, name: a.account.name, legalName: a.account.legal_name, lifecycle: a.account.lifecycle,
      website: a.account.website, domain, notes: a.account.notes, segment: a.account.segment, source: a.account.source,
      contacts: (a.contacts ?? []).map((c) => ({ id: c.id, name: `${c.first_name ?? ""} ${c.last_name ?? ""}`.trim(), email: c.email, phone: c.phone, position: c.position, role: c.role_in_deal, primary: !!c.is_primary })),
      companies: (a.companies ?? []).map((c) => ({ id: c.id, legalName: c.legal_name, registrationNo: c.registration_no, taxId: c.tax_id, vatId: c.vat_id, billingEmail: c.billing_email, address: [c.street, c.postal_code, c.city].filter(Boolean).join(", ") || null, primary: !!c.is_primary })),
      deals: (a.deals ?? []).map((d) => ({ id: d.id, ref: d.ref, title: d.title, stage: d.stage, value: d.value ?? null, nextStep: d.nextStep ?? null, nextStepOn: d.nextStepOn ?? null })),
      projects: (a.projects ?? []).map((p) => ({ id: p.id, code: p.code, name: p.name, status: p.status, url: p.url })),
      tasks: (a.openTasks ?? []).map((t) => ({ id: t.id, title: t.title, due: t.due_on ?? null })),
      notes_: (a.latestNotes ?? []).map((n) => ({ at: n.created_at, kind: n.kind ?? "note", body: n.body })),
      mail, invoices: inv,
    };
  }
  const a = await json(KUBOARD, "account_get", { account: ref });
  const domain = a.website ? host(a.website) : null;
  const emails = (a.contacts ?? []).map((c) => c.email).filter(Boolean);
  const mail = await courierMail(domain, emails);
  return {
    business, id: a.id, ref: a.ref, name: a.name, legalName: a.legal_name, lifecycle: a.lifecycle, website: a.website, domain, notes: a.notes,
    segment: a.segment, source: a.source, industry: a.industry, employees: a.employee_band, leadStatus: a.lead_status,
    contacts: (a.contacts ?? []).map((c) => ({ id: c.id, name: `${c.first_name ?? ""} ${c.last_name ?? ""}`.trim(), email: c.email, phone: c.phone, position: c.position, role: c.role_in_deal, primary: !!c.is_primary })),
    companies: (a.legalEntities ?? []).map((c) => ({ id: c.id, legalName: c.legal_name, registrationNo: c.registration_no, taxId: c.tax_id, vatId: c.vat_id, billingEmail: c.billing_email, address: c.address ?? null, primary: !!c.is_default })),
    deals: (a.deals ?? []).map((d) => ({ id: d.id, ref: d.ref, title: d.title, stage: d.stage ?? null, value: cents(d.one_off_cents) || null, mrr: cents(d.mrr_cents), seats: d.seats ?? null })),
    projects: [],
    tasks: (a.openTasks ?? []).map((t) => ({ id: t.id, title: t.title, due: t.due_on ?? null })),
    notes_: (a.timeline ?? []).map((n) => ({ at: n.created_at, kind: n.kind ?? "note", body: n.body })),
    tenants: a.tenants ?? [], charges: a.activeCharges ?? [],
    mail, invoices: await kuboardInvoices(a.id),
  };
}

// ---- writes (`brain crm-do <business> <action> <json>`) ----
// The CRM app's own clicks: one action name for both businesses, translated to each CRM's tool. Only these actions exist;
// every write is logged in data/crm-audit.jsonl.
const ACTIONS = {
  // drag a card to another column; a lost stage takes a reason
  move_deal: {
    "10t": (a) => [TEN_T, "upsert_deal", { id: a.deal, stage: a.stage, ...(a.lostReason ? { lostReason: a.lostReason } : {}) }],
    kudosky: (a) => [KUBOARD, "deal_move", { deal: a.deal, stage: a.stage, ...(a.lostReason ? { lossReason: a.lostReason } : {}) }],
  },
  task_done: {
    "10t": (a) => [TEN_T, "upsert_task", { id: a.task, done: !a.reopen }],
    kudosky: (a) => [KUBOARD, a.deal ? "deal_task_done" : "task_done", { task: a.task, ...(a.reopen ? { reopen: true } : {}) }],
  },
  task_add: {
    "10t": (a) => [TEN_T, "upsert_task", { title: a.title, ...(a.due ? { dueOn: a.due } : {}), ...(a.deal ? { deal: a.deal } : { account: a.account }) }],
    kudosky: (a) => a.deal ? [KUBOARD, "deal_task_add", { deal: a.deal, title: a.title, ...(a.due ? { dueOn: a.due } : {}) }]
      : [KUBOARD, "task_add", { account: a.account, title: a.title, ...(a.due ? { dueOn: a.due } : {}) }],
  },
  note_add: {
    "10t": (a) => [TEN_T, "add_note", { body: a.body, ...(a.deal ? { deal: a.deal } : { account: a.account }) }],
    kudosky: (a) => a.deal ? [KUBOARD, "deal_note_add", { deal: a.deal, body: a.body, kind: a.kind ?? "note" }]
      : [KUBOARD, "note_add", { account: a.account, body: a.body, kind: a.kind ?? "note" }],
  },
  // 10T keeps the next step on the deal; in Kuboard the next step is the deal's nearest open task
  next_step: {
    "10t": (a) => [TEN_T, "upsert_deal", { id: a.deal, nextStep: a.text || null, nextStepOn: a.on || null }],
    kudosky: (a) => [KUBOARD, "deal_task_add", { deal: a.deal, title: a.text, ...(a.on ? { dueOn: a.on } : {}) }],
  },
  deal_save: {
    "10t": (a) => [TEN_T, "upsert_deal", clean({ id: a.id, account: a.id ? undefined : a.account, title: a.title, stage: a.stage, value: a.value, expectedCloseOn: a.expectedCloseOn, probability: a.probability })],
    kudosky: (a) => a.id ? [KUBOARD, "deal_update", clean({ deal: a.id, title: a.title, seats: a.seats, pricePerSeat: a.pricePerSeat, mrr: a.mrr, expectedCloseOn: a.expectedCloseOn })]
      : [KUBOARD, "deal_create", clean({ account: a.account, title: a.title, stage: a.stage, seats: a.seats, pricePerSeat: a.pricePerSeat })],
  },
  account_create: {
    "10t": (a) => [TEN_T, "upsert_account", clean({ name: a.name, website: a.website, lifecycle: a.lifecycle ?? "lead", segment: a.segment, notes: a.notes })],
    kudosky: (a) => a.lead ? [KUBOARD, "lead_create", clean({ name: a.name, website: a.website, source: a.source })]
      : [KUBOARD, "account_create", clean({ name: a.name, website: a.website, lifecycle: a.lifecycle, segment: a.segment, source: a.source, notes: a.notes })],
  },
  contact_save: {
    "10t": (a) => [TEN_T, "upsert_contact", clean({ account: a.account, id: a.id, firstName: a.firstName, lastName: a.lastName, email: a.email, phone: a.phone, position: a.position })],
    kudosky: (a) => [KUBOARD, "contact_create", clean({ account: a.account, firstName: a.firstName, lastName: a.lastName, email: a.email, phone: a.phone, position: a.position })],
  },
  company_save: {
    "10t": (a) => [TEN_T, "upsert_company", clean({ account: a.account, id: a.id, legalName: a.legalName, registrationNo: a.registrationNo, taxId: a.taxId, vatId: a.vatId, billingEmail: a.billingEmail, street: a.street, city: a.city, postalCode: a.postalCode, country: a.country })],
  },
  lead_status: {
    kudosky: (a) => [KUBOARD, "lead_update", clean({ account: a.account, status: a.status, disqualifyReason: a.reason })],
  },
};

function clean(o) {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined && v !== ""));
}

export async function act(business, action, args = {}) {
  if (action === "invoice_draft" && business === "10t") return invoiceDraft(args);
  const make = ACTIONS[action]?.[business];
  if (!make) throw new Error(`${business} doesn't support ${action}`);
  const [server, tool, input] = make(args);
  const t0 = Date.now();
  try {
    const out = await json(server, tool, input);
    appendLine(p("crm-audit.jsonl"), { at: new Date().toISOString(), business, action, tool: `${server}.${tool}`, input, ok: true, ms: Date.now() - t0 });
    return { ok: true, business, action, result: out };
  } catch (e) {
    appendLine(p("crm-audit.jsonl"), { at: new Date().toISOString(), business, action, tool: `${server}.${tool}`, input, ok: false, error: e.message });
    throw e;
  }
}
