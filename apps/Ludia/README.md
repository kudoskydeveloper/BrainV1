# Ľudia

Osobné CRM v jednom okne, zo série `com.lockedin.*` v Hangari (`com.lockedin.ludia`). Pri každom človeku na jednom mieste:
posledný kontakt na každom kanáli, firma a skupina, narodeniny a meniny, čo sme riešili, čo som sľúbil, a zoznam „ozvi sa“
pre ľudí, s ktorými som dlho nehovoril.

- **Ozvi sa:** ľudia, ktorých sledujem (hviezdička v detaile, s intervalom: každý týždeň až raz za rok), a posledný kontakt je
  starší ako interval. Počet je aj červený odznak na dlaždici v Hangari.
- **Zabúdaš:** silné kontakty (veľa správ, mailov, meetingov), ktoré nesledujem a je s nimi ticho dlhšie ako 60 dní.
- **Oslavy:** rozsah 2 týždne / mesiac / 3 mesiace / rok (nad mesiac po mesiacoch). Všetky narodeniny z kalendára Narodeniny
  aj z iných kalendárov („Mamina narodeniny“, „Rudi narodeniny 🎂“) a z Kontaktov; meniny z kalendára Meniny (2 týždne)
  a ďalej zo slovenského kalendára mien (`brain/src/namedays-sk.json`), len pre kontakty s tým menom. Nespárované
  narodeniny majú **Priradiť k človeku…**: Brain si meno zapamätá (`birthday_names`) a ďalej ich priradí sám.
- **Narodeniny pri človeku:** z Kontaktov, z kalendára (rovnaké alebo podobné meno) alebo ručne (Pridať / Upraviť v karte
  Kontakt, rok je voliteľný); pri dátume je vidieť, odkiaľ je.
- **Hľadanie:** podľa mena, firmy, mailu, čísla a poznámky; od 3 znakov aj podľa témy: s kým si o tom písal v mailoch
  (Courier), na WhatsAppe, v Beeperi a v názvoch meetingov, s ukážkou; v detaile je potom karta s týmito správami.
- **Triedenie** (panel s nástrojmi): posledný kontakt, najdlhšie bez kontaktu, meno, najsilnejší vzťah.
- **Sľuby:** sľuby pridané v detaile (Enter), odškrtnúť = splnené. Cez Brain: „sľúbil som Jane ponuku“.
- **Sledovaní, Všetci, Skupiny** (10T, Kudosky, Práca, Súkromné; odhad z domén, meetingov a WhatsApp skupín,
  zmena kliknutím na odznak v detaile). Hľadanie: meno, firma, e-mail, telefón, poznámka.
- **Detail:** WhatsApp / Správa / Zavolať / E-mail, posledný kontakt po kanáloch, sľuby, poznámka, otvorené úlohy v Todoiste
  (oba účty, podľa mena), posledné správy z WhatsAppu a Beeperu, maily z Courieru (otvárajú sa v Courieri), meetingy,
  poznámky z Brainu. Skryť = už sa neukáže.
- **Zlúčiť s… (duplikáty):** v detaile v paneli s nástrojmi alebo pravým klikom na človeka. Navrchu sú podobní (rovnaké
  priezvisko a podobné krstné meno, napr. Stanka / Stanislava, alebo len priezvisko „Bielikova“), dá sa hľadať aj podľa
  mena, mailu či čísla; vyberieš, ktoré meno zostane. Spoja sa kanály, poznámky, sľuby aj sledovanie. Zlúčenie je uložené
  v Brainе (`links` v `data/ludia.json`), takže drží aj po obnovení; **Rozdeliť** ho vráti.
- **Zdroje (⌘,):** pri každom zdroji „brať do úvahy“ a „pridáva ľudí“. Bez „pridáva ľudí“ zdroj len doplní posledný kontakt
  ľuďom, ktorí už v zozname sú. Predvolene: WhatsApp (chaty 1:1 s aspoň 5 správami), e-mail (aspoň raz tam aj späť),
  meetingy, Messenger, iMessage a Telegram pridávajú; Kontakty, Instagram a LinkedIn len dopĺňajú. Beeper vždy len chaty
  1:1, nikdy skupiny.
- **Pracovné CRM (Zdroje, voliteľné):** ľubovoľný čítací nástroj ľubovoľného MCP servera, ktorý pozná Brain, s argumentmi
  ako JSON (`{email}` a `{name}` sa nahradia) a skupinami, pre ktoré sa pýta (predvolene Práca). V detaile je potom karta
  s tým, čo vráti. V kóde nie je žiadna firma; pri zmene práce sa zmení len toto nastavenie (`crm` v `data/ludia.json`).
- Dáta z Brainu: `node ~/Developer/brain/src/cli.js ludia` (`brain/src/ludia.js`), detail `ludia-person <id>`, zmeny
  `ludia-set <id> <json>`, zlúčenie `ludia-merge <id> <id druhého>` a `ludia-split <id>`, nástroje pre CRM `ludia-crm-tools`, hľadanie témy `ludia-search <téma>`, zdroje `ludia-sources <json>`. Moje doplnky (sledovanie, poznámky, sľuby, skrytí, zdroje) sú
  v `~/Developer/brain/data/ludia.json`. MCP v Brainе: `people_overview`, `person`, `people_search`, `person_update`.
- Posledný výsledok je v `~/Library/Application Support/Ludia`, takže okno sa otvorí hneď s dátami. ⌘R obnoví.
- URL: `ludia://due`, `ludia://fading`, `ludia://celebrations`, `ludia://promises`, `ludia://followed`, `ludia://all`,
  `ludia://refresh`. Hangar ich používa.
- `Ludia --snapshot <dir> [ludia.json]` vykreslí zoznamy, detail a zdroje do PNG (svetlé aj tmavé).
- Build a inštalácia: `./build-app.sh`. Ikona: `Icon/make-icns.sh` (koralová → purpurová, postava v otvorenej dráhe s bodkou).
