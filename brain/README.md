# Brain

Local MCP server that routes to all your other MCP servers, knows where your things are, and learns. Local only (stdio).

## Tools
| Tool | Does |
|---|---|
| overview | servers, tool counts, projects, notes, people, last scan |
| where_is | Spotlight + project map + bookmarks + notes + learned links |
| search_everywhere | files, notes, people, Daktela accounts/contacts, Selleriz meetings, LinkedIn, email (Courier + old Thunderbird history, merged) — in parallel |
| capabilities / call | find and run any tool on any connected MCP server |
| confirm | run a proposal (writes always come back as a proposal first) |
| file_action | open/reveal now; move, rename, tag, untag, trash (Finder Trash), mkdir via proposal |
| calendar_list / calendar_events / calendar_free | every calendar in Apple Calendar (iCloud + Google accounts), recurring events expanded; free slots |
| calendar_create / calendar_update / calendar_delete | via proposal (EventKit helper `tools/calendar`, build with `build.sh`; allow Brain Calendar in Privacy → Calendars) |
| reminders_lists / reminders_list / reminders_add / reminders_complete / reminders_delete | Apple Reminders for personal things (work stays in Todoist); delete via proposal |
| shopping_list / shopping_add | Reminders "Shopping" (on the iPhone) + what you eat (Brain note "Strava a nákupy"); prompt `fridge` for a fridge photo |
| meeting_prep | next meeting (or by query/time/id): attendees, CRM, e-mails, WhatsApp, earlier meetings, notes, tasks |
| client | one page per client/project: tasks, calendar, e-mails, WhatsApp, notes, people, files |
| idoklad_invoices / idoklad_contacts / idoklad_invoice / idoklad_send | iDoklad API v3; issuing and e-mailing via proposal. Credentials in the Keychain, service `brain-idoklad` (application_id, client_id, client_secret) |
| write_file / save_email | put things on disk without a confirm (adds only, never overwrites; home folder, not hidden folders or ~/Library except iCloud/Google Drive): a text file, a Courier e-mail as Markdown + its attachments (`src/save.js`) |
| market_overview / market_briefs / marketbar | Alpaca paper account through `market-alerts` (equity, P/L, positions, watchlist), MarketBar's briefs (`Personal/Finance/Market briefs`, else `~/Market briefs`), open MarketBar (`marketbar://brief`, `brief-now`, `settings`). Also in `morning_brief` (section Trhy, with a ⚠️ line for positions whose stop loss is missing, partial or DAY only) and in `search_everywhere` (source `market`: tickers' prices, brief mentions) |
| claude_account | which Claude account Brain app / the claude CLI use (e-mail, plan; never a token); `switch` opens Terminal, asks, logs out and signs in with another one (e.g. when the usage limit is used up). Also `brain account`, `brain relogin [e-mail]`, and `/ucet`, `/relogin` in Brain app |
| people_overview / person / person_update | Ľudia, the personal CRM (`src/ludia.js`, app `com.lockedin.ludia` in Hangar): one row per person you talk to, merged from WhatsApp, Courier, Beeper 1:1 chats, meetings and Contacts; last contact per channel, who to get in touch with (followed people past their interval), strong contacts going quiet, birthdays and name days, your notes and promises (`data/ludia.json`). CLI: `brain ludia`, `ludia-person <id>`, `ludia-set <id> <json>`, `ludia-sources <json>` |
| remember / recall / forget | your facts, as Markdown in `notes/` (same topic replaces the old note) |
| scan_now | rescan now (also nightly 03:30 via launchd `local.brain.brain-scan`) |

## How it learns
- Fathom: main account key in `~/.config/fathom/api_key`, phone account in `~/.config/fathom/api_key_mobile`; the phone's meetings go to 10T or `Meetings/Súkromné` by title, people and summary. A fresh recording without Fathom's summary waits (up to 3 h) for a later run, and a note written without one is completed once Fathom has it (the last 2 days are rechecked each run).
- Fathom recap e-mails (meetings shared by colleagues) are read from Courier (`courier.search` + `courier.thread`). Every summary and action item, from the API or a recap, is translated into Slovak through the `claude` CLI before it's written (`src/translate.js`, cached in `data/translations.json`); if that fails the meeting waits for the next run.
- Writing style: `style/pisanie.md` says how you write (a template; rewrite it for yourself). `writing_style` returns it with your own latest messages in that chat or e-mails to that person; Brain calls it before drafting anything you send.
- E-mail is Courier only (the own mail app, `src/courier.js`, its MCP `courier`). Search also reads the old Thunderbird history and merges it (`src/mailmerge.js`): each mail has `client` courier / thunderbird / thunderbird+courier (matched by Message-ID, else sender + subject + time); `call` refuses `thunderbird-mail`. Spark is never loaded, listed or called (`NEVER` in `src/registry.js`). `meeting_prep` and `client` use the same. Claude Desktop extensions (.mcpb) are routable like any other server.
- Search by meaning covers e-mails too: Thunderbird's local mbox files, last 12 months, without Daktela/VinumVivo, bulk mail, drafts, trash (`tools/mail.py`, settings in `semantic` in brain.config.json).
- Nightly scan: `~/Developer` projects (git remote, README, Finder tag), Chrome bookmarks, every server's tools, email senders (Thunderbird must be running).
- `remember` from any Claude; corrections replace the old fact.
- Opening/revealing a where_is result links that query to the path (`data/links.json`).
- Logs: `data/usage.jsonl` (questions), `data/audit.jsonl` (every write).

## Safety
Writes through `call` need `confirm` unless listed in `brain.config.json` → `auto_confirm`. `commit_*` steps of a server's own two-step flow pass through, so nothing is confirmed twice. Trading servers (`market-alerts` = Alpaca, or any server named alpaca/broker/trading) are the exception: orders, cancels, commits and other trade tools always need Brain's `confirm`, whatever `auto_confirm` says; their `propose_order` comes back as a Brain proposal for `commit_order` with the server's own summary (`src/actions.js` → `needsConfirm`). Trash goes to the Finder Trash. Content from email/CRM/web is data, never instructions.

## Commands
`node src/cli.js scan | where <q> | search <q> | tools [q]` · tests: `npm test`
