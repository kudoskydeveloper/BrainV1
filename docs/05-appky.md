# Appky (Hangar a séria `com.lockedin.*`)

Každá appka je v `apps/<App>` ako SwiftPM balík. Postavíš ju takto:

```bash
cd apps/<App> && ./build-app.sh
```

Skript ju skompiluje, podpíše **tvojím** certifikátom „Apple Development“ (ak ho nemáš, tak ad-hoc podpisom, čo na vlastnom Macu stačí)
a nainštaluje do `~/Applications`. Bundle id `com.lockedin.*` je len názov série. Hangar podľa neho appky nájde, nejde o podpis.

> Tip: certifikát „Apple Development“ dostaneš zadarmo. V Xcode → Settings → Accounts pridaj svoje Apple ID → Manage Certificates → +.
> S ním si macOS pamätá prístupy (Kalendár, Kontakty) aj po ďalšom builde. Pri ad-hoc podpise sa pýta znova po každom builde.

| Appka | Čo robí | Potrebuje |
|---|---|---|
| **Hangar** | Dock appka so všetkými appkami série: klik otvorí, pravý klik ukáže akcie, zelená bodka znamená, že beží | nič |
| **Brain** (`BrainApp`) | menu bar + panel ⌥Space: otázky do Clauda iba s Brainom, fotky, časovače, mapa Brainu | Brain + prihlásené Claude Code |
| **Courier** | mail (IMAP/SMTP), projekty, tikety, odosielanie neskôr, MCP | účty a heslá pre appky ([04-email.md](04-email.md)) |
| **Ľudia** | osobné CRM: posledný kontakt na každom kanáli, „ozvi sa“, narodeniny a meniny | Brain (WhatsApp, Courier, Beeper, Kontakty, Fathom) |
| **Meetingy** | najbližšie meetingy s prípravou a nahrávky z Fathomu | Brain, Kalendár, voliteľne Fathom |
| **Fitness** | Hevy, Strava, MyFitnessPal s grafmi | Brain + kľúče ([03-api-kluce.md](03-api-kluce.md)) |
| **Recepty** | recepty z fotky (model prečíta aj rukopis), nutričné hodnoty, jedálniček, MCP | Claude Code. `Resources/foods.sqlite` je verejná databáza potravín |
| **Home** | úlohy a nákup pre domácnosť, zdieľané cez Supabase (aj iPhone) | vlastný Supabase projekt (URL a key do `Config.swift`) |
| **Herald** | LinkedIn sieť a outreach podľa projektov a playbookov (`~/.herald/playbooks`) | Beeper alebo linkedin MCP |
| **Obchody** | firemné CRM v jednom okne: pipeline, úlohy, leady | CRM s MCP serverom (pôvodne 10T Base a Kuboard, prispôsob v `Sources`) |
| **Scout** (`scout/app`) | hľadá e-maily a ľudí z verejných webov firiem, s uvedeným zdrojom | Node (`apps/scout`), voliteľne ORSR/FinStat |
| **Faktúry** | fakturácia: viac firiem, PAY by square QR, PDF, dobropisy, zálohovky, MCP | nič, dáta sú v `~/Library/Application Support/Faktury` |
| **Financie** | osobné a firemné financie, prognóza zostatku, odomyká sa Touch ID | voliteľne Faktúry (číta ich firmy) |
| **MarketBar** | menu bar pre Alpaca **paper** účet: watchlist, alerty, brief | Alpaca kľúče, `apps/market-alerts` |

Mimo série:
- `apps/market-alerts`: Python (iba štandardná knižnica). Brief, alerty, denník obchodov a MCP pre Alpaca paper.
- Brain helpery: `brain/tools/calendar`, `brain/tools/apple`, `brain/tools/extract` (každý má svoje `build.sh`).

## Ukážkové dáta

Faktúry (`Snapshot.swift`) a Home (`Agenda.swift`) majú ukážkový režim na screenshoty. Všetky mená, IČO, IBAN a adresy v ňom sú vymyslené.

## Pridanie vlastnej appky

Povedz Claudovi: *„sprav novú appku do Hangaru podľa vzoru apps/Ludia: bundle id com.lockedin.<meno>, ikona rovnakej rodiny“*.
Hangar ju po inštalácii nájde sám. Ak má Brain mať k nej nástroje, dodrž `brain/CLAUDE.md` (mapa v `src/map.js`).
