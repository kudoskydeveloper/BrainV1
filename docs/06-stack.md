# Náš stack

Takto to používame my. Ber to ako inšpiráciu, nie ako povinnosť. Čo nepoužívaš, vynechaj.

| Oblasť | Nástroj | Ako je napojený |
|---|---|---|
| AI | **Claude** (Max predplatné), Claude Code + Claude Desktop | Brain ako MCP v oboch, Brain app cez `claude -p` |
| Mail | **Courier** (vlastný) nad Gmail/Workspace a iCloud | IMAP, `courier-mcp` |
| Kalendár | Apple Calendar s Google a iCloud účtami | EventKit (`Brain Calendar.app`) |
| Úlohy | **Todoist** (pracovné, dva účty pre dve firmy) + Apple Pripomienky (osobné, nákup) | Todoist MCP, Pripomienky cez EventKit |
| Meetingy | **Fathom** (nahrávanie) → poznámky v iCloud Drive → úlohy do Todoistu | Fathom API + recap maily, preklad do slovenčiny cez `claude` |
| Správy | WhatsApp (história lokálne), **Beeper** (Messenger, IG, Telegram, LinkedIn, iMessage, posielanie) | WhatsApp DB + Beeper Desktop API |
| CRM | firemné CRM s MCP (u nás 10T Base, Kuboard, Daktela, Selleriz), osobné: **Ľudia** | MCP servery cez Brain router |
| Leady | **Scout** (e-maily z webov), **Herald** (LinkedIn outreach) | vlastné MCP |
| Súbory | iCloud Drive, Google Drive for desktop, `~/Developer` | Spotlight + nočný scan |
| Poznámky | Apple Notes + Brain notes (Markdown) | `Brain Apple.app`, `remember` |
| Fitness | Hevy, Strava, MyFitnessPal | API + `mfp-mcp` |
| Peniaze | **Faktúry** + **Financie** (lokálne), voliteľne iDoklad | vlastné MCP, iDoklad API v3 |
| Trading | Alpaca **paper** + MarketBar | `market-alerts` MCP |
| Domácnosť | **Home** nad Supabase | REST + RLS |
| Vyhľadávanie podľa významu | Ollama + `embeddinggemma` | lokálne embeddingy (`src/semantic.js`) |
| Kód | GitHub, Swift 6 / SwiftUI, Node 22, Python 3 | všetko bez externých frameworkov, okrem MCP SDK a zod |

## Princípy, ktoré držíme

1. **Lokálne najprv.** Dáta ostávajú na Macu (SQLite, Markdown, Keychain). Cloud iba tam, kde treba zdieľať (Home).
2. **Jeden vstup.** Claude vidí iba Brain a Brain smeruje ďalej. Menej konfigurácie a jedno miesto na pravidlá.
3. **Návrh → potvrdenie.** Nič sa nepošle, nezmaže ani neobjedná bez tvojho „áno“.
4. **Jeden kanál na jednu vec.** Mail iba Courier, kalendár iba Apple Calendar. Claude potom nehádá, ktorý z nástrojov použiť.
5. **Appky sú malé.** Každá rieši jednu vec, má vlastnú SQLite a MCP. Hangar ich drží pokope.
