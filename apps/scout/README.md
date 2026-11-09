# Scout

Finds e-mail addresses for companies and people from their public websites, with a source for every address. A core
(`src/`) used by an MCP server (Brain, Claude), a CLI and the Scout Hangar app; part of the CRM plan (phase 4) in 10T Todoist.

- **A company** (`scout company firma.sk`): reads at most ~15 pages of its site (home, then its own links to contact /
  team / about / imprint / careers / GDPR pages; the usual paths only when it has no such links), finds addresses in
  mailto links, plain text, obfuscated forms (`meno [at] firma [dot] sk`, `(zavináč)`) and Cloudflare's e-mail protection.
  Each address: the page it was on, a bit of context, when, and its kind: **person** (their name is on the site),
  **generic** (info@, kariera@, faktury@ …) or **other**. Plus MX (does the domain take mail) and the **pattern** learned
  from people's addresses (first.last, flast, f.last, first, …; one-word patterns need two people, the company's own name
  doesn't count).
- **A person** (`scout person "Ing. Jana Nováková" firma.sk`): **found** (the exact address is on the site), **pattern**
  (built from the learned pattern) or **mx** (a common-pattern guess, with alternatives). Never verified by SMTP: from a
  home IP that gets you blacklisted, and many servers accept everything anyway.
- **Enrichment (Apollo-style)**: the same pages also give **phones** (tel: links, +421/+420, SK mobiles), **social profiles**
  (LinkedIn company, Facebook, Instagram, X, YouTube; a person's LinkedIn URL is kept, never opened), **people named with a
  role** on team / contact pages ("Ing. Jana Nováková – konateľka", "Peter Kováč / Head of Sales") with **seniority** (owner,
  c-level, director, manager, staff) and their address (found, or from the learned pattern), and the company's **IČO**, which
  is looked up in the registry: **RegisterUZ** (SK) or **ARES** (CZ), both free and official → official name, legal form,
  address, kraj, founded, industry (SK NACE / CZ-NACE) and employees (bucket 1-9, 10-49, 50-249, 250-999, 1000+). People who
  disappear from the site are dropped on the next read, unless looked up by hand or in a list.
- **Every registered SK and CZ company** (`scout import cz`, `scout import sk`, `src/bulk.js`), from the official open data, no
  crawling: CZ from ČSÚ RES (`res_data.csv`, twice a month), SK from ŠÚ SR RPO (full dump in the public `susr-rpo` bucket,
  daily changes next to it). Only legal entities, not sole traders. SK also brings the current statutory bodies (konatelia,
  predstavenstvo; liquidators left out) as people with origin `registry`: name, title and role, never their home address. Files
  go to `~/.scout/bulk/`. First import (8. 11. 2026): CZ 1 525 328 companies (943 845 live), SK 669 873 (504 192 live) and
  595 802 people, 1,05 GB, ~2,5 min. Search hides dissolved companies unless `--includeDissolved`; `--nace=6201` filters by code.
  **Kept up to date** by `scout update`: every SK daily change file since the last one applied (whole current records; a
  dissolved company loses its registry people), and the CZ file again when ČSÚ has published a newer one (twice a month).
  `scripts/install-update-agent.sh` runs it every day at 6:30 with launchd (`com.lockedin.scout-update`, log
  `~/.scout/update.log`; a run missed while the Mac sleeps happens at wake).
- **People database and search** (`scout people --role=marketing --seniority=owner,c-level --industry=reklam --size=10-49
  --region=Bratislavský --email`, `scout companies …`): filters over everyone Scout has found.
- **Lists** (`scout lists add "Q4 IT firmy" jana.novakova@firma.sk firma.sk`, `show`, `remove`, `delete`) and **CSV export**
  (`scout export --list="Q4 IT firmy"`, Nekontaktovať left out): the input for Courier sequences and Obchody.
- **Nekontaktovať** (`scout block <email|domain>`, `--undo`) and **delete on request** (`scout forget <email|domain>`:
  every trace removed, and it stays on the list).

Rules: robots.txt is read first, an honest User-Agent (`ScoutBot/0.1`), ~1.2 s between pages, at most 15 pages per
domain, a company is read again after a month (`--fresh` sooner). LinkedIn profiles are never opened for addresses.

Data: `~/.scout/scout.sqlite` (SQLite, WAL; `src/db.js`): `orgs` (registered companies by country + IČO, with or without a
website), `sites` (websites read, linked to their org by the IČO on the site), `emails` / `phones` / `socials` (each with its
page), `people`, `lists` / `list_members`, `blocked`. Plain SQL so it can move to Postgres/Supabase later. Also
`~/.scout/blocked.json` (Nekontaktovať, rewritten on every change; Courier checks it before each sequence e-mail),
`~/.scout/codes.json` (NACE and size code lists) and `~/.scout/audit.log`. The old `store.json` is imported once on first run
and kept as `store.json.imported`.

## Scout app
`app/` is the Hangar app (`com.lockedin.scout`): Firmy, Ľudia, Nekontaktovať; ⌘F looks up a domain (and a name); a company
shows its addresses by kind with the page each was on, copy / write / nekontaktovať / delete, and "Prečítať znova". Links:
`scout://company/<domain>`, `scout://person?name=…&domain=…` (Obchody and Herald use them), `scout://people`,
`scout://blocked`. Build and install: `app/build-app.sh`. Icon: `app/Icon/make-icns.sh` (lime → green binoculars; sketch in
`Hangar/icon-ideas/scout-a-dalekohlad.svg`).

## Use
- `npm install`, then `node src/cli.js …` (JSON on stdout).
- MCP: `claude mcp add -s user scout -- node ~/Developer/scout/src/index.js` (Brain picks it up from `~/.claude.json`).
  Tools: `scout_company`, `scout_person`, `scout_people`, `scout_companies`, `scout_lists`, `scout_export`, `scout_list`,
  `scout_block`, `scout_forget`.
- Tests: `npm test`.
