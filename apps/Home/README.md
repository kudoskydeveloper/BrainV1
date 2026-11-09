# Home

Úlohy a nákup pre celú domácnosť, zo série `com.lockedin.*` v Hangari (`com.lockedin.home`). Jediná appka zo série, ktorej dáta
nie sú len v Macu: domácnosť je v Supabase, aby ju zdieľali všetci členovia (neskôr aj na iPhone).

- **Dnes:** čo zostáva (podľa časti dňa), týždenné a mesačné úlohy, čo mešká, dnešné plány z kalendárov a čo kúpiť.
- **Úlohy:** opakovanie raz / každý deň / v určité dni / raz za N týždňov alebo mesiacov (v ktorýkoľvek deň, aj len v
  niektorých mesiacoch) / niekedy medzi dvoma dňami; kto (člen, ktokoľvek, striedame sa po týždňoch); kto čo spravil za 30 dní.
- **Nákup:** spoločný zoznam (viac položiek naraz oddelených čiarkou, dvojklik premenuje).
- **Plán:** najbližších 14 dní: kalendáre Macu (EventKit) a úlohy.
- **Zariadenia:** zatiaľ ukážka (byt z Android appky: 8 miestností, svetlá, žalúzie, klíma, reproduktory, TV, vysávač, dvere,
  alarm, 6 scén s vrátením späť). Tvar ako entity Home Assistantu, aby sa dal zdroj vymeniť; stav sa nesynchronizuje
  (je to živý stav bytu), ukážka sa ukladá do `devices.json`.
- **Domácnosť:** názov, členovia, kód pozvánky, účet, zmena hesla.

## Ako to funguje

- **HomeCore** (bez UI, aj pre budúci iPhone): model a rozvrh úloh (`Model.swift`, `Agenda.swift`), Supabase cez REST bez SDK
  (`Supabase.swift`), lokálna kópia + fronta zmien (`Store.swift`): každá zmena sa hneď uloží do
  `~/Library/Application Support/Home/household.json`, odošle sa o sekundu, zmeny ostatných sa sťahujú každých 30 s.
  Riadok so zmenou ešte vo fronte drží lokálnu verziu, inak vyhráva novšia zo servera.
- **Supabase:** projekt `YOUR-PROJECT-REF` (vlastný Supabase projekt, free tier; spí po týždni bez dopytov; URL a publishable key do `Sources/HomeCore/Config.swift` a `brain/src/home.js`). Schéma v
  `supabase/migrations` (prvá je z pôvodnej Android appky ~/Developer/HomeApp, tvar JSON v stĺpci `repeat` je rovnaký).
  Všetko je za RLS: člen vidí len svoju domácnosť. `supabase db push --linked` po novej migrácii.
- **Prihlásenie:** e-mail a heslo. Zabudnuté heslo: odkaz e-mailom (otvorí `home://auth#…` a appka sa prihlási), potom
  Domácnosť › Zmeniť heslo. Registrácia je zatvorená: nového člena treba pridať v Supabase › Authentication › Users › Add user.
  Prvý vytvorí domácnosť, ďalší sa pridá kódom z Domácnosti. Sign in with Apple príde s plateným Apple Developer účtom.
- **Brain:** `brain/src/home.js` ide priamo do Supabase s reláciou appky (`session.json`, 0600): `shopping_list`,
  `shopping_add`, `shopping_done`, `home_tasks`, `home_task_add`, `home_task_done`. Rozvrh úloh je tam prepísaný do JS;
  pri zmene `Model.swift`/`Agenda.swift` uprav aj ten.

**iPhone** (`Sources/HomeMobile`, tabs Dnes, Úlohy, Nákup, Byt, Domácnosť, nad tým istým HomeCore):
`./install-iphone.sh` s pripojeným iPhonom (USB alebo rovnaká Wi-Fi) ho podpíše bezplatným Apple tímom a nainštaluje cez
`ios/Home.xcodeproj`. Podpis vyprší po 7 dňoch, takže raz za týždeň znova (dáta ostanú). Prvýkrát: v iPhone Nastavenia ›
Všeobecné › Správa VPN a zariadení › dôverovať vývojárovi. Simulátor: `./build-ios.sh`.

Build: `./build-app.sh` → `~/Applications/Home.app`. Testy: `swift test`. Návrh bez klikania: `Home --snapshot <dir>` (demo dáta,
svetlý aj tmavý režim). Ikona: `Icon/make-icns.sh`. Odkazy: `home://today`, `tasks`, `shopping`, `plan`, `devices`, `household`, `sync`.

Zatiaľ nie: skutočné zariadenia (Home Assistant, viď HARDWARE.md v HomeApp), pôdorys bytu, automatizácie, Brain nástroje na zariadenia, Sign in with Apple a TestFlight (čaká na platený Apple Developer účet).
