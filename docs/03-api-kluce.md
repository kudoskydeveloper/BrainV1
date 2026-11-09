# API kľúče a integrácie: kde čo zohnať

Všetko je voliteľné. Čo nepripojíš, Brain preskočí (alebo to vypni v `brain.config.json → "off"`).
**Kľúče nikdy nedávaj do repozitára ani do chatu.** Patria do `brain/data/` (je v .gitignore), `~/.config/…`, Keychainu alebo `~/.claude.json`.

`brain` = `node ~/Developer/brain/src/cli.js`

## Bez kľúča (stačí prístup v macOS)

| Zdroj | Čo treba |
|---|---|
| Apple Kalendár (aj Google a Exchange účty pridané do macOS) | Nastavenia → Internetové účty pridať účty, `brain/tools/calendar/build.sh`, povoliť **Brain Calendar** v Súkromie → Kalendáre a Pripomienky |
| Apple Pripomienky, Poznámky, Fotky, Kontakty, Skratky | `brain/tools/apple/build.sh`, povoliť **Brain Apple** pri prvej otázke |
| WhatsApp (čítanie histórie) | WhatsApp pre Mac nainštalovaný a prihlásený, Full Disk Access pre Terminal/Claude. Posielanie ide cez Beeper (nižšie) |
| Safari história a záložky, Chrome záložky | Full Disk Access |
| Súbory | Spotlight. Brain hľadá v iCloud Drive, Dokumentoch, Google Drive (Drive for desktop) a `~/Developer` |
| Vyhľadávanie podľa významu | `brew install ollama && ollama pull embeddinggemma`, potom `semantic_reindex`. Všetko beží lokálne |
| Claude (Brain app, preklady) | prihlásené Claude Code (`claude`), používa tvoje predplatné. API kľúč netreba |

## S kľúčom alebo prihlásením

| Služba | Na čo | Kde zohnať | Kam dať |
|---|---|---|---|
| **Todoist** | úlohy, akčné body z meetingov | oficiálny MCP: `claude mcp add -s user --transport http todoist https://ai.todoist.net/mcp`, prihlásenie cez OAuth. Alternatíva lokálne: `npx @doist/todoist-ai` s `TODOIST_API_KEY` (Todoist → Nastavenia → Integrácie → Developer) | `~/.claude.json` (spraví to príkaz). Druhý účet pridáš pod iným menom, napr. `todoist-firma` |
| **Fathom** | nahrávky meetingov → poznámky + úlohy | fathom.video → Settings → API Access → Generate key (platený plán) | `~/.config/fathom/api_key` (druhý účet: `api_key_mobile`). Potom `brain fathom` |
| **Beeper** | Messenger, Instagram, Telegram, LinkedIn, iMessage, posielanie WhatsApp | Beeper Desktop (beeper.com), v ňom Settings → Developers → zapnúť Desktop API | `brain beeper-login` a schváliť v Beeperi → `brain/data/beeper.json` |
| **Hevy** | silový tréning | hevy.com/settings?developer (Hevy Pro) → API key | skopírovať kľúč a spustiť `brain hevy-key` (zoberie ho zo schránky) |
| **Strava** | aktivity | strava.com/settings/api → vytvoriť aplikáciu (Callback domain: `localhost`) → Client ID + Secret | `brain strava-setup`, potom `brain strava-login` |
| **MyFitnessPal** | kalórie, makrá | komunitný server `mfp-mcp` (Python, cez `uv`: `brew install uv`), prihlásenie podľa jeho README | `claude mcp add -s user myfitnesspal -- uvx mfp-mcp` |
| **Alpaca** (paper trading) | MarketBar, `market_overview` | alpaca.markets → Paper account → API Keys → Generate | `~/.config/market-alerts/keys.env` podľa `apps/market-alerts/keys.env.example`. MCP: `claude mcp add -s user market-alerts -e PYTHONPATH=$HOME/Developer/market-alerts -- python3 -m market_alerts.mcp_server` |
| **iDoklad** | faktúry v iDoklade | app.idoklad.cz → Nastavenia → API → nová aplikácia (Client ID + Secret) | `brain idoklad-login` → uloží do Keychainu (služba `brain-idoklad`). Ak používaš appku Faktúry, nechaj `idoklad` v `"off"` |
| **Supabase** (appka Home) | zdieľaná domácnosť | supabase.com → New project → Settings → API: Project URL + publishable key | `apps/Home/Sources/HomeCore/Config.swift` a `brain/src/home.js` (`URL_`), schéma: `supabase db push` z `apps/Home` |
| **Google Drive** | súbory | Google Drive for desktop (súbory sú potom lokálne v `~/Library/CloudStorage`) | nič, Brain ich nájde sám |
| **LinkedIn** (Herald, Scout) | siete a outreach | vlastný `linkedin-mcp` server (nie je súčasťou balíka). Bez neho Herald beží len s Beeperom | `claude mcp add -s user linkedin -- …` |
| **Ľubovoľné CRM s MCP** (napr. 10T Base, Kuboard, Daktela, Selleriz) | firemné CRM v `search_everywhere`, `meeting_prep`, Obchody | od poskytovateľa CRM | HTTP server s OAuth: `brain.config.json → "remote": { "meno": "https://…/mcp" }` a `brain connect meno`. Stdio: `claude mcp add` |

## Kontrola

```bash
node ~/Developer/brain/src/cli.js tools
```

Vypíše všetky servery, ktoré Brain vidí, aj s ich nástrojmi. V Claude to isté ukáže `overview`.
