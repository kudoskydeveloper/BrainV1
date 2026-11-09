# Brain kit

Lokálny „druhý mozog“ pre Mac, ktorý ovládaš cez Clauda. Obsahuje:

- **Brain**: MCP server v Node.js. Sedí medzi Claudom a všetkým ostatným: súbormi, kalendárom, mailom, WhatsAppom, poznámkami, CRM, Todoistom aj fitness. Navyše si pamätá, čo mu povieš.
- **Hangar**: Dock appka, ktorá spúšťa celú sériu vlastných appiek (`com.lockedin.*`).
- **13 appiek** v SwiftUI: Brain (panel cez ⌥Space), Courier (mail), Ľudia (osobné CRM), Meetingy, Fitness, Recepty, Home (domácnosť),
  Herald (LinkedIn outreach), Obchody (firemné CRM), Faktúry, Financie, MarketBar (paper trading) a Scout (hľadanie kontaktov).

Všetko beží lokálne na tvojom Macu. Dáta ostávajú v `~/Library/Application Support/<App>` a v `brain/data`. **V tomto repozitári
nie sú žiadne osobné dáta**, iba kód, prázdne šablóny a vymyslené ukážkové údaje (pozri [docs/07-sukromie.md](docs/07-sukromie.md)).

## Rýchly štart (5 minút + kľúče)

```bash
git clone https://github.com/kudoskydeveloper/BrainV1.git ~/Developer/BrainV1
```

```bash
cd ~/Developer/BrainV1 && ./setup.sh
```

Potom otvor Claude Code v tomto priečinku a napíš:

> **Nastav mi Brain podľa CLAUDE.md.**

Claude ťa prevedie zvyškom: povie ti, ktoré kľúče a kde treba zohnať, vyplní `brain.config.json`, pripojí mail a postaví
appky, ktoré chceš. Kto chce všetko naraz, spustí `./setup.sh --apps` (build všetkých appiek trvá 5–15 min).

## Požiadavky

| Čo | Prečo | Ako |
|---|---|---|
| macOS 26 (Tahoe) | appky používajú Liquid Glass (Brain server ide aj na staršom) | Aktualizácia softvéru |
| Xcode 26 / Swift 6.2+ | build appiek a natívnych helperov | App Store → Xcode, potom `sudo xcode-select -s /Applications/Xcode.app` |
| Node.js 20+ | Brain server, Scout | `brew install node` |
| Claude Code | mozog celého systému | `npm install -g @anthropic-ai/claude-code` a potom `claude` (prihlásenie) |
| Claude Desktop (voliteľné) | chat s Brainom mimo terminálu | claude.ai/download |
| Ollama (voliteľné) | vyhľadávanie podľa významu, všetko lokálne | `brew install ollama && ollama pull embeddinggemma` |
| Python 3.9+ | market-alerts, pár skriptov | je v macOS (Xcode CLT) |

## Dokumentácia

| | |
|---|---|
| [docs/00-zaciatok.md](docs/00-zaciatok.md) | inštalácia krok za krokom (aj bez Clauda) |
| [docs/01-ako-to-funguje.md](docs/01-ako-to-funguje.md) | architektúra: Claude → Brain → MCP servery a appky |
| [docs/02-mcp.md](docs/02-mcp.md) | čo je MCP, ako ho pridať do Claude Code a Desktopu, ako ho Brain nájde |
| [docs/03-api-kluce.md](docs/03-api-kluce.md) | každá integrácia: kde zohnať kľúč, kam ho dať |
| [docs/04-email.md](docs/04-email.md) | mail cez Courier (IMAP, heslá pre appky pre Gmail, iCloud a Outlook) |
| [docs/05-appky.md](docs/05-appky.md) | všetky appky: čo robia, čo potrebujú, ako ich postaviť |
| [docs/06-stack.md](docs/06-stack.md) | náš stack a čo z neho je voliteľné |
| [docs/07-sukromie.md](docs/07-sukromie.md) | kde sú dáta, čo odchádza z Macu a čo nikdy necommitovať |
| [docs/08-problemy.md](docs/08-problemy.md) | časté problémy |

## Štruktúra

```
brain/            MCP server (src/), testy, natívne helpery (tools/), config
apps/             Hangar + všetky appky (SwiftPM), market-alerts (Python), scout (Node + appka)
docs/             návody
setup.sh          inštalácia
CLAUDE.md         inštrukcie pre Clauda, ako to nastaviť a rozvíjať
```
