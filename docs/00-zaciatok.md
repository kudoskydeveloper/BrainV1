# Inštalácia krok za krokom

Najjednoduchšie: spusti `./setup.sh`, otvor v tomto priečinku Claude Code a napíš „nastav mi Brain podľa CLAUDE.md“.
Ak to chceš spraviť ručne, postupuj takto:

## 1. Nástroje

```bash
xcode-select --install
```

```bash
brew install node
```

```bash
npm install -g @anthropic-ai/claude-code
```

Na appky potrebuješ plný **Xcode 26** z App Store. Po inštalácii ho raz otvor, nech dobehnú komponenty. Potom:

```bash
sudo xcode-select -s /Applications/Xcode.app
```

## 2. Repozitár a Brain

```bash
git clone https://github.com/kudoskydeveloper/BrainV1.git ~/Developer/BrainV1
```

```bash
cd ~/Developer/BrainV1 && ./setup.sh
```

`setup.sh` spraví toto:
- vytvorí odkazy `~/Developer/brain`, `~/Developer/market-alerts` a `~/Developer/scout` (appky ich hľadajú tam),
- nainštaluje npm závislosti a spustí testy,
- postaví natívne helpery Brainu: `Brain Calendar.app` (kalendár a pripomienky), `Brain Apple.app` (Poznámky, Fotky, Skratky) a `brain-extract` (OCR, PDF),
- zaregistruje MCP `brain` v Claude Code (`claude mcp add -s user brain -- node ~/Developer/brain/src/server.js`).

## 3. Kto si

Uprav `brain/brain.config.json` podľa `brain/brain.config.example.json`. Doplň hlavne svoje mená a adresy (`dossier.me`, `ludia.me`),
domény kolegov (`dossier.team_domains`) a predvolený kalendár. Bez týchto údajov Brain nevie, kto si ty a kto ostatní na meetingu.

## 4. Kľúče a integrácie

Prejdi [03-api-kluce.md](03-api-kluce.md) a pripoj, čo chceš. Všetko je voliteľné, Brain chýbajúce zdroje preskočí.

## 5. Appky

```bash
cd apps/Hangar && ./build-app.sh
```

Rovnako postavíš každú ďalšiu appku (`apps/<App>/build-app.sh`), alebo všetky naraz cez `./setup.sh --apps`. Hangar si potom
pripni do Docku.

## 6. Prístupy v macOS

Systémové nastavenia → Súkromie a bezpečnosť:
- **Kalendáre, Pripomienky:** Brain Calendar
- **Kontakty, Fotky, Automatizácia (Notes):** Brain Apple
- **Full Disk Access:** Terminal / Claude (ak chceš WhatsApp históriu, Safari a Apple Notes databázu)

## 7. Overenie

```bash
node ~/Developer/brain/src/cli.js scan
```

V Claude Code (alebo Desktop) potom skús: *„čo mám zajtra?“*, *„kde je zmluva s …?“*, *„zapamätaj si, že …“*.
