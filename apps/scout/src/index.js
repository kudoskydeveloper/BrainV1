#!/usr/bin/env node
// Scout as an MCP server (stdio): for Brain (`call scout …`) and Claude. The same operations as the CLI and the app.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { block, company, exportCsv, forget, lists, overview, person, searchCompanies, searchPeople } from "./scout.js";

const server = new McpServer({ name: "scout", version: "0.2.0" });
const text = (v) => ({ content: [{ type: "text", text: JSON.stringify(v, null, 2) }] });
const run = (f) => async (a) => { try { return text(await f(a)); } catch (e) { return { isError: true, content: [{ type: "text", text: e.message }] }; } };

server.registerTool("scout_company", {
  description: "Everything about a company from its website and the registry: e-mail addresses (each with the page it was on and kind person / generic / other), phones, social profiles (LinkedIn, Facebook, …), people named on the site with their role and seniority (and their likely address), the address pattern (first.last, flast, …), MX, and the registry record found by the IČO on the site (SK RegisterUZ / CZ ARES: official name, legal form, address, industry, employees, founded). Reads at most ~15 pages, respects robots.txt, cached for a month (fresh: true reads again).",
  inputSchema: { domain: z.string().describe("e.g. firma.sk or https://www.firma.sk"), fresh: z.boolean().optional() },
  annotations: { readOnlyHint: true },
}, run(({ domain, fresh }) => company(domain, { fresh })));

server.registerTool("scout_person", {
  description: "A person's likely e-mail at a company, with how sure it is: found (the exact address is on the website), pattern (built from the pattern learned from colleagues' addresses there), mx (a common-pattern guess; the domain takes mail; alternatives listed). Never verified by SMTP. Also returns the company's generic addresses. Check `blocked` (nekontaktovať) before writing.",
  inputSchema: { name: z.string().describe("first and last name, titles are dropped"), domain: z.string(), fresh: z.boolean().optional() },
  annotations: { readOnlyHint: true },
}, run((a) => person(a)));

server.registerTool("scout_list", {
  description: "Overview: companies looked up (name, industry, size, how many addresses / phones / people), people, lists and the nekontaktovať list.",
  inputSchema: {},
  annotations: { readOnlyHint: true },
}, run(() => overview()));

const filters = {
  q: z.string().optional().describe("text in name, role, company or domain"),
  industry: z.string().optional().describe("words of the industry, e.g. 'programovanie', 'reklam'"),
  size: z.array(z.enum(["1-9", "10-49", "50-249", "250-999", "1000+"])).optional().describe("employee buckets"),
  region: z.string().optional().describe("kraj or city, e.g. 'Bratislavský', 'Brno'"),
  country: z.enum(["SK", "CZ"]).optional(),
  nace: z.string().optional().describe("NACE code prefix, e.g. '62' (IT), '7311' (advertising agencies)"),
  includeDissolved: z.boolean().optional().describe("also companies that no longer exist"),
  list: z.string().optional().describe("only members of this list"),
  limit: z.number().optional(),
};

server.registerTool("scout_people", {
  description: "Search the people Scout knows (Apollo-style): filter by role words, seniority (owner, c-level, director, manager, staff), company, industry or NACE, size, region, list, origin, or only those with an address that is not on Nekontaktovať. People come from the business register (origin registry: konatelia and boards of every live SK company, no e-mail until their company's site is read), company websites (origin site) and lookups (origin lookup); each has its address confidence (found / pattern / mx) and sources.",
  inputSchema: { ...filters, role: z.string().optional().describe("e.g. 'marketing', 'obchod', 'CEO'"), seniority: z.array(z.enum(["owner", "c-level", "director", "manager", "staff"])).optional(),
    domain: z.string().optional(), emailOnly: z.boolean().optional(), origin: z.enum(["registry", "site", "lookup"]).optional() },
  annotations: { readOnlyHint: true },
}, run((a) => searchPeople(a)));

server.registerTool("scout_companies", {
  description: "Search every registered SK and CZ company (official registers, imported in bulk) and the websites Scout has read: by text, industry words or NACE code, employee size bucket (CZ; SK once enriched), region (kraj) or city, country, list, withSite. Dissolved companies are left out unless includeDissolved. Each row has the registry data (name, IČO, legal form, founded, industry, employees) and, for companies whose site Scout read, how many addresses, phones and people it found.",
  inputSchema: { ...filters, withSite: z.boolean().optional().describe("only companies whose website Scout has read") },
  annotations: { readOnlyHint: true },
}, run((a) => searchCompanies(a)));

server.registerTool("scout_lists", {
  description: "Saved lists of prospects (for a Courier sequence, Obchody or a CSV). action: all (default), show, create, add, remove, delete. members: person ids (as scout_people returns them), e-mails of known people, or company domains. Local only.",
  inputSchema: { action: z.enum(["all", "show", "create", "add", "remove", "delete"]).optional(), name: z.string().optional(), members: z.array(z.string()).optional() },
}, run((a) => lists(a)));

server.registerTool("scout_export", {
  description: "A list (or a scout_people search) as CSV: name, email, confidence, role, seniority, company, domain, phone. Addresses on Nekontaktovať are left out.",
  inputSchema: { list: z.string().optional(), ...filters, role: z.string().optional(), seniority: z.array(z.string()).optional(), emailOnly: z.boolean().optional() },
  annotations: { readOnlyHint: true },
}, async (a) => { try { return { content: [{ type: "text", text: exportCsv(a) }] }; } catch (e) { return { isError: true, content: [{ type: "text", text: e.message }] }; } });

server.registerTool("scout_block", {
  description: "Nekontaktovať: add an address or a whole domain to the do-not-contact list (undo: true removes it). Local only.",
  inputSchema: { target: z.string().describe("an e-mail or a domain"), undo: z.boolean().optional() },
}, run(({ target, undo }) => block(target, { undo })));

server.registerTool("scout_forget", {
  description: "Delete on request (GDPR): removes every stored trace of an address or a domain and puts it on the nekontaktovať list. Only when the user asks.",
  inputSchema: { target: z.string() },
}, run(({ target }) => forget(target)));

await server.connect(new StdioServerTransport());
