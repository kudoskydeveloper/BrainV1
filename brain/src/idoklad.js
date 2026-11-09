// iDoklad (invoicing) through its API v3. Credentials live in the macOS Keychain (service "brain-idoklad"), never in files;
// the access token stays in memory only. Two ways in:
// - a Developer-portal app (client_id + client_secret + redirect uri): log in once with `node src/cli.js idoklad-login`,
//   which stores a refresh_token in the Keychain;
// - client credentials (application_id + client_id + client_secret from iDoklad settings → API), no browser needed.
// Reads run now; issuing an invoice and e-mailing it always come back as a proposal (actions.js) to confirm.
import { execFile } from "node:child_process";
import http from "node:http";
import { promisify } from "node:util";
import { fold } from "./notes.js";
import { p } from "./paths.js";
import { appendLine } from "./store.js";
import { status } from "./ui.js";

const run = promisify(execFile);
const API = "https://api.idoklad.cz/v3";
const KEYCHAIN = "brain-idoklad";
let tok = null;   // { access_token, until }

async function secret(account) {
  try { return (await run("security", ["find-generic-password", "-s", KEYCHAIN, "-a", account, "-w"])).stdout.trim(); }
  catch { return ""; }
}

const IDENTITY = "https://identity.idoklad.cz/server";
export const REDIRECT = "http://localhost:53682/idoklad/callback";   // must be the Redirect uri of the app on developer.idoklad.cz

async function store(account, value) {
  await run("security", ["add-generic-password", "-U", "-s", KEYCHAIN, "-a", account, "-w", value]);
}

async function tokenRequest(url, params) {
  const r = await fetch(url, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(params), signal: AbortSignal.timeout(20000) });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || !j.access_token) throw new Error(`iDoklad login failed (${r.status}): ${j.error_description || j.error || "no token"}`);
  return j;
}

async function token() {
  if (tok && Date.now() < tok.until) return tok.access_token;
  const [application_id, client_id, client_secret, refresh_token] = await Promise.all(["application_id", "client_id", "client_secret", "refresh_token"].map(secret));
  if (!client_id || !client_secret) throw new Error(`iDoklad isn't set up: store client_id and client_secret in the Keychain under "${KEYCHAIN}"`);
  let j;
  if (refresh_token) {
    j = await tokenRequest(`${IDENTITY}/connect/token`, { grant_type: "refresh_token", client_id, client_secret, scope: "idoklad_api offline_access", refresh_token })
      .catch((e) => { throw new Error(`${e.message}. Log in again: node src/cli.js idoklad-login`); });
    if (j.refresh_token && j.refresh_token !== refresh_token) await store("refresh_token", j.refresh_token);
  } else if (application_id) {
    j = await tokenRequest(`${IDENTITY}/v2/connect/token`, { grant_type: "client_credentials", application_id, client_id, client_secret, scope: "idoklad_api" });
  } else throw new Error("iDoklad: not logged in yet. Run once in Terminal: node ~/Developer/brain/src/cli.js idoklad-login");
  tok = { access_token: j.access_token, until: Date.now() + (j.expires_in - 60) * 1000 };
  return tok.access_token;
}

/** One-time browser login for a Developer-portal app: opens iDoklad, catches the redirect locally, keeps the refresh token. */
export async function login() {
  const [client_id, client_secret] = await Promise.all(["client_id", "client_secret"].map(secret));
  if (!client_id || !client_secret) throw new Error(`store client_id and client_secret first (security add-generic-password -U -s ${KEYCHAIN} -a client_id -w)`);
  const state = Math.random().toString(36).slice(2);
  const code = await new Promise((resolve, reject) => {
    const srv = http.createServer((req, res) => {
      const u = new URL(req.url, REDIRECT);
      if (u.pathname !== "/idoklad/callback") { res.writeHead(404).end(); return; }
      const ok = u.searchParams.get("state") === state && u.searchParams.get("code");
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" })
        .end(ok ? "<h2>Brain je prihlásený do iDokladu. Toto okno môžeš zavrieť.</h2>" : `<h2>Prihlásenie zlyhalo: ${u.searchParams.get("error") || "neplatná odpoveď"}</h2>`);
      srv.close();
      ok ? resolve(ok) : reject(new Error(u.searchParams.get("error") || "bad callback"));
    }).on("error", (e) => reject(e.code === "EADDRINUSE" ? new Error("another idoklad-login is still waiting (port 53682); finish it in the browser or stop it with Ctrl+C first") : e))
      .listen(53682, "127.0.0.1");
    setTimeout(() => { srv.close(); reject(new Error("no answer from iDoklad within 5 minutes")); }, 300000);
    const url = `${IDENTITY}/connect/authorize?${new URLSearchParams({ scope: "idoklad_api offline_access", client_id, response_type: "code", redirect_uri: REDIRECT, state })}`;
    console.log("Otváram iDoklad v prehliadači. Prihlás sa a povoľ prístup…");
    run("open", [url]).catch(() => console.log(url));
  });
  const j = await tokenRequest(`${IDENTITY}/connect/token`, { grant_type: "authorization_code", client_id, client_secret, scope: "idoklad_api offline_access", code, redirect_uri: REDIRECT });
  if (!j.refresh_token) throw new Error("iDoklad gave no refresh token (is offline_access allowed for the app?)");
  await store("refresh_token", j.refresh_token);
  tok = { access_token: j.access_token, until: Date.now() + (j.expires_in - 60) * 1000 };
  return "Brain je prihlásený do iDokladu (obnovovací token je v Keychaini).";
}

async function api(method, path, body) {
  const r = await fetch(API + path, { method, headers: { Authorization: `Bearer ${await token()}`, "Content-Type": "application/json", Accept: "application/json" },
                                     body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(30000) });
  const j = await r.json().catch(() => null);
  if (!r.ok || j?.IsSuccess === false) throw new Error(`iDoklad ${method} ${path.split("?")[0]}: ${r.status} ${j?.Message || ""} ${JSON.stringify(j?.Data?.Errors || j?.Errors || "").slice(0, 300)}`.trim());
  return j?.Data ?? j;
}

const q = (s) => encodeURIComponent(String(s).replace(/[~|()]/g, " "));
const day = (d = new Date()) => d.toLocaleDateString("sv-SE");
const money = (n, cur = "€") => `${Number(n).toLocaleString("sk-SK", { minimumFractionDigits: 2, maximumFractionDigits: 2 })} ${cur}`;
const PAY = { 0: "neuhradená", 1: "uhradená", 2: "čiastočne uhradená", 3: "preplatená" };

function contactOut(c) {
  return { id: c.Id, name: c.CompanyName || [c.Firstname, c.Surname].filter(Boolean).join(" "), email: c.Email || undefined,
           ico: c.IdentificationNumber || undefined, dic: c.VatIdentificationNumberSk || c.VatIdentificationNumber || undefined, city: c.City || undefined };
}

export async function contacts({ query, limit = 10 } = {}) {
  status(`Hľadám kontakt v iDoklade${query ? ` „${query}“` : ""}`);
  const f = query ? `&filter=(CompanyName~ct~${q(query)})` : "";
  const d = await api("GET", `/Contacts?page=1&pagesize=${limit}${f}`);
  let items = d.Items || [];
  if (!items.length && query) {   // a person rather than a company, or matched by e-mail
    const all = (await api("GET", `/Contacts?page=1&pagesize=200`)).Items || [];
    items = all.filter((c) => fold(`${c.CompanyName} ${c.Firstname} ${c.Surname} ${c.Email}`).includes(fold(query))).slice(0, limit);
  }
  return items.map(contactOut);
}

function invoiceOut(i) {
  const cur = i.CurrencyId === 2 ? "Kč" : "€";
  return { id: i.Id, number: i.DocumentNumber, partner: i.PartnerAddress?.CompanyName || i.PartnerName || i.PartnerAddress?.NickName, description: i.Description,
           issued: String(i.DateOfIssue || "").slice(0, 10), due: String(i.DateOfMaturity || "").slice(0, 10),
           total: i.Prices ? money(i.Prices.TotalWithVat, cur) : undefined, status: PAY[i.PaymentStatus] ?? i.PaymentStatus,
           sent: i.IsSentToPurchaser ? "odoslaná" : "neodoslaná", partner_email: i.PartnerAddress?.Email || undefined };
}

export async function invoices({ query, unpaid = false, limit = 15 } = {}) {
  status(`Pozerám vydané faktúry v iDoklade${unpaid ? " (neuhradené)" : ""}`);
  const filters = [unpaid && "PaymentStatus~eq~0", query && `Description~ct~${q(query)}`].filter(Boolean);
  const d = await api("GET", `/IssuedInvoices?page=1&pagesize=${limit}&sort=DateOfIssue~desc${filters.length ? `&filter=(${filters.join("~and~")})` : ""}`);
  let items = (d.Items || []).map(invoiceOut);
  if (query && !items.length) {   // the client's name is on the partner, not in the description
    const recent = ((await api("GET", `/IssuedInvoices?page=1&pagesize=100&sort=DateOfIssue~desc${unpaid ? "&filter=(PaymentStatus~eq~0)" : ""}`)).Items || []).map(invoiceOut);
    items = recent.filter((i) => fold(`${i.partner} ${i.description} ${i.number}`).includes(fold(query))).slice(0, limit);
  }
  return items;
}

async function partnerOf(partner) {
  if (/^\d+$/.test(String(partner))) return contactOut(await api("GET", `/Contacts/${partner}`));
  const found = await contacts({ query: partner, limit: 5 });
  if (!found.length) throw new Error(`no iDoklad contact "${partner}". Create it in iDoklad first (or check the name with idoklad_contacts).`);
  if (found.length > 1 && !found.some((c) => fold(c.name) === fold(partner)))
    throw new Error(`"${partner}" matches several contacts: ${found.map((c) => `${c.name} (id ${c.id})`).join(", ")}. Pass the id.`);
  return found.find((c) => fold(c.name) === fold(partner)) || found[0];
}

// the fields POST /IssuedInvoices accepts; the rest of the Default model is read-only
const POST_FIELDS = ["AccountNumber", "BankId", "ConstantSymbolId", "CurrencyId", "DateOfIssue", "DateOfMaturity", "DateOfPayment", "DateOfTaxing",
  "DateOfVatApplication", "DeliveryAddressId", "Description", "DiscountPercentage", "DocumentSerialNumber", "EetResponsibility", "ExchangeRate",
  "ExchangeRateAmount", "HasVatRegimeOss", "Iban", "IsEet", "IsIncomeTax", "Items", "ItemsTextPrefix", "ItemsTextSuffix", "Note", "NumericSequenceId",
  "OrderNumber", "PartnerId", "PaymentOptionId", "ReportLanguage", "SalesOrderId", "Swift", "VariableSymbol", "VatOnPayStatus", "VatReverseChargeCodeId"];
const ITEM_FIELDS = ["Amount", "Code", "DiscountName", "DiscountPercentage", "IsTaxMovement", "ItemType", "Name", "PriceListItemId", "PriceType", "Unit", "UnitPrice", "VatCodeId", "VatRate", "VatRateType"];
const pick = (o, keys) => Object.fromEntries(keys.filter((k) => o[k] !== undefined && o[k] !== null).map((k) => [k, o[k]]));

/** Build an invoice from iDoklad's own defaults (number series, bank account, VAT settings) and return it as a proposal. */
export async function planInvoice({ partner, items, description, due_days, issue_date, note, order_number, variable_symbol, prices_with_vat = false }) {
  const c = await partnerOf(partner);
  status(`Beriem predvolenú faktúru z iDokladu (číselná rada, účet, DPH)`);
  const def = await api("GET", "/IssuedInvoices/Default");
  const tmpl = def.Items?.[0] || {};
  const issued = issue_date || day();
  const due = new Date(`${issued}T12:00:00`); due.setDate(due.getDate() + (due_days ?? (def.DateOfMaturity && def.DateOfIssue ? Math.round((Date.parse(def.DateOfMaturity) - Date.parse(def.DateOfIssue)) / 86400000) : 14)));
  const body = pick({ ...def, PartnerId: c.id, Description: description || items[0].name, DateOfIssue: issued, DateOfTaxing: issued, DateOfMaturity: day(due),
    Note: note ?? def.Note, OrderNumber: order_number ?? def.OrderNumber, VariableSymbol: variable_symbol ?? def.VariableSymbol,
    Items: items.map((it) => pick({ ...tmpl, Name: it.name, Amount: it.amount ?? 1, UnitPrice: it.unit_price, Unit: it.unit ?? tmpl.Unit ?? "ks",
      PriceType: prices_with_vat ? 0 : 1, DiscountPercentage: 0, IsTaxMovement: false, ItemType: 0, ...(it.vat_rate !== undefined ? { VatRate: it.vat_rate } : {}) }, ITEM_FIELDS)) }, POST_FIELDS);
  const sum = items.reduce((s, it) => s + (it.amount ?? 1) * it.unit_price, 0);
  const cur = body.CurrencyId === 2 ? "Kč" : "€";
  const summary = [`Vystaviť faktúru v iDoklade pre ${c.name}${c.ico ? ` (IČO ${c.ico})` : ""}`, `Popis: ${body.Description}`,
    ...items.map((it) => `- ${it.name}: ${it.amount ?? 1} × ${money(it.unit_price, cur)}`),
    `Spolu ${prices_with_vat ? "s DPH" : "bez DPH"}: ${money(sum, cur)} · vystavená ${issued} · splatná ${body.DateOfMaturity}`,
    "Faktúra sa len vystaví, neodošle sa (na odoslanie je idoklad_send)."].join("\n");
  return { action: { type: "idoklad", op: "invoice", body, what: `${c.name}: ${body.Description}` }, summary };
}

export async function planSend({ id, other_recipients, subject, body: text, copy_to_me = true }) {
  const i = invoiceOut(await api("GET", `/IssuedInvoices/${id}`));
  const to = [i.partner_email, ...(other_recipients || [])].filter(Boolean);
  if (!to.length) throw new Error(`invoice ${i.number} has no partner e-mail in iDoklad; pass other_recipients`);
  return { action: { type: "idoklad", op: "send", what: `${i.number} → ${to.join(", ")}`,
                     body: { DocumentId: Number(id), SendToPartner: !!i.partner_email, SendToSelf: copy_to_me, SendToAccountant: false,
                             ...(other_recipients?.length ? { OtherRecipients: other_recipients } : {}), ...(subject ? { EmailSubject: subject } : {}), ...(text ? { EmailBody: text } : {}) } },
           summary: `Odoslať e-mailom faktúru ${i.number} (${i.partner}, ${i.total}, splatná ${i.due}) na ${to.join(", ")}${copy_to_me ? ", kópia tebe" : ""}.${i.sent === "odoslaná" ? " Pozor: už raz odoslaná bola." : ""}` };
}

export async function exec(a) {
  if (a.op === "invoice") {
    status("Vystavujem faktúru v iDoklade");
    const r = await api("POST", "/IssuedInvoices", a.body);
    appendLine(p("audit.jsonl"), { idoklad: "invoice", what: a.what, id: r.Id, number: r.DocumentNumber });
    return { issued: invoiceOut(r), next: "Not sent yet. To e-mail it, use idoklad_send with this id (after the user agrees)." };
  }
  status("Odosielam faktúru e-mailom cez iDoklad");
  const r = await api("POST", "/Mails/IssuedInvoice/Send", a.body);
  appendLine(p("audit.jsonl"), { idoklad: "send", what: a.what, sent: r.Sent, not_sent: r.NotSent });
  return { sent: r.Sent, not_sent: r.NotSent };
}
