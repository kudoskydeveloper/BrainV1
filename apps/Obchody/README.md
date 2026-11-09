# Obchody

The business CRMs in one window, part of the `com.lockedin.*` family in Hangar (`com.lockedin.obchody`): **10T** (10T Base) and
**Kudosky** (Kuboard), without going to their web apps. Phase 1 of the plan in 10T Todoist ("CRM: Hangar appka nad 10T Base a
Kuboard"): phase 1 (reading), phase 2 (writes) and phase 3 (invoicing).

- **Dnes:** tasks due today or late in both CRMs, open deals with no next step or a late one, new Kudosky leads; totals.
- **Pipeline:** a board per business, a column per open stage (won and lost with "Uzavreté"), cards with value or MRR and
  the next step. A card opens the client.
- **Writes (your clicks):** drag a card to another column (Prehraté asks why), right-click a deal for next step, move,
  note, task or edit; tick a task off; in a client's detail add a task, note, deal or contact, and edit billing data (10T).
  The board changes at once and goes back if the CRM refuses. Brain translates each action to the CRM's own tool
  (`brain crm-do <10t|kudosky> <action> <json>`, a fixed list in `brain/src/crm.js`) and logs it in
  `brain/data/crm-audit.jsonl`. Kuboard has no "next step" field: there it's the deal's nearest open task.
- **Invoicing:** a won 10T deal → right-click "Koncept faktúry vo Faktúrach" (or "Koncept z obchodu" in the client's
  Faktúry card): a draft issued by 10T Studios for the client's IČO with one line (the deal's title and value); Faktúry
  opens on it and you issue it there. Kudosky shows the subscription and Kuboard's invoices (`invoice_list` in Kuboard's MCP).
- **Nájsť e-mail** (Scout, phase 4): a contact without an e-mail gets a button in the client detail; Scout reads the client's website and returns the address as found / by the company's pattern / a guess. 10T saves it to the contact; "E-maily z webu" opens the client in Scout.
- **Klienti** (sortable table), **Úlohy** (late / today / this week / later), **Leady** (Kuboard).
- **Client detail** (inspector): deals, tasks, contacts, billing data (IČO, DIČ, IČ DPH), invoices from Faktúry by IČO
  (10T) or the subscription (Kudosky), mail from Courier by domain and contacts' addresses (opens in Courier), projects,
  notes and activity.

Data from Brain: `node ~/Developer/brain/src/cli.js crm` and `crm-account <10t|kudosky> <account>` (`brain/src/crm.js`),
which reads the CRMs through their own MCP servers: `weare10t-chat` (10T Base) and `kuboard` (remote, signed in with
`brain connect kuboard`). The last result is cached in `~/Library/Application Support/Obchody`. ⌘R reloads; coming back to the
window after 2 minutes reloads too. The Hangar badge counts late tasks.

- URL: `obchody://today`, `obchody://pipeline/<10t|kudosky>`, `obchody://accounts/…`, `obchody://tasks/…`, `obchody://leads/kudosky`, `obchody://refresh`.
- `Obchody --snapshot <dir> [crm.json] [account.json]` renders Dnes, cards, leads and a client to PNG (light and dark).
- Build and install: `./build-app.sh`. Icon: `Icon/make-icns.sh` (tangerine → burnt orange, the O of Obchody with the pipeline board inside; sketch in `Hangar/icon-ideas/obchody-b-pipeline.svg`).
