# Brain kit: inštrukcie pre Clauda

Pomáhaš niekomu nastaviť Brain a appky na jeho Macu. Hovor po slovensky, jednoducho, po jednom kroku. Nikdy nepredpokladaj,
že používateľ je programátor.

## Keď povie „nastav mi Brain“

1. **Kontrola:** spusti `./setup.sh` (ak ešte nebežal) a prečítaj výstup. Chýbajúce požiadavky vysvetli podľa README.
2. **Kto je:** opýtaj sa na meno, pracovné a súkromné e-maily, firemné domény. Zapíš ich do `brain/brain.config.json`
   (`dossier.me`, `dossier.team_domains`, `ludia.me`, `fathom.me`, `calendar.default_calendar`). Vzor je v `brain/brain.config.example.json`.
3. **Čo chce používať:** ukáž zoznam integrácií z `docs/03-api-kluce.md` a opýtaj sa, ktoré chce. Pre každú vybranú
   ho preveď získaním kľúča (presné kroky sú v tom dokumente). Kľúč nech vloží sám do súboru alebo Keychainu. **Kľúče
   ani heslá nikdy nepýtaj do chatu a nikdy ich nezapisuj do repozitára.**
4. **Integrácie, ktoré nechce:** pridaj ich id do `"off"` v `brain.config.json` (napr. `"idoklad"`, `"market"`, `"fitness"`).
5. **MCP:** over cez `claude mcp list`, že `brain` je pripojený. Pre Claude Desktop pridaj Brain do
   `~/Library/Application Support/Claude/claude_desktop_config.json` (návod v `docs/02-mcp.md`). Pred zápisom súbor prečítaj
   a nič existujúce neprepíš.
6. **Mail:** ak chce mail, postav Courier (`apps/Courier/build-app.sh`), nech si v ňom pridá účty (docs/04-email.md) a
   pripoj `courier` MCP.
7. **Appky:** opýtaj sa, ktoré chce, a postav ich `./build-app.sh` v ich priečinku (Hangar vždy). Každá sa nainštaluje do
   `~/Applications`. Prvé spustenie si vypýta prístupy (Kalendár, Kontakty, Fotky, Full Disk Access pre WhatsApp a Safari).
8. **Štýl písania:** ponúkni, že podľa jeho odoslaných mailov prepíšeš `brain/style/pisanie.md`.
9. **Test:** `node brain/src/cli.js scan` a potom v Claude: „čo mám dnes v kalendári?“, „nájdi zmluvu“.

## Pravidlá

- Osobné dáta (`brain/data/`, `brain/notes/`, `brain/brain.config.json` s vyplnenými údajmi, `~/Library/Application Support/*`,
  kľúče) **nikdy necommituj ani nepushuj**. Pred každým commitom pozri `git status` a `git diff --cached`.
- Zápisy cez Brain (poslanie správy, mailu, udalosti, mazanie) idú vždy ako návrh: ukáž ho a `confirm` volaj až po áno.
- Pri rozvíjaní Brainu dodrž `brain/CLAUDE.md` (mapa nástrojov v `src/map.js`, `npm test` pred commitom).
- Integrácie, ktoré používateľ nemá (Daktela, Selleriz, 10T Base, Kuboard, iDoklad…), Brain sám preskočí. Nič nevymýšľaj
  a nepýtaj kľúče k niečomu, čo nechce.
