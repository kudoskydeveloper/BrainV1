# Financie

Osobné a firemné financie v jednom okne, zo série `com.lockedin.*` (Brain, Courier, Faktúry, Fitness, Meetingy, Hangar).
Zostatky na účtoch, príjmy a výdavky, pravidelné položky s tým, čo ešte čaká, prognóza zostatku. Odomyká sa odtlačkom prsta.

- **Peňaženky a účty:** Osobné plus každá firma. Firmy sa berú z Faktúr (len čítanie ich databázy), s bežným účtom na ich IBAN.
  Účet má počiatočný zostatok k dátumu; **Zosúladiť** zapíše rozdiel oproti zostatku v banke ako korekciu.
- **Pohyby:** príjem, výdavok (s kategóriou, komu, poznámkou), prevod medzi mojimi účtami aj firma ↔ osobné (výplata,
  dividenda). V súhrne jednej peňaženky sa prevod z inej peňaženky počíta ako príjem, v súhrne všetkého nie.
- **Pravidelné položky:** príjem, výdavok alebo prevod; suma fixná, variabilná (odhad), fixná + variabilná zložka (plat
  s bonusom) alebo nepravidelná (raz, ročne); týždenne až ročne, každý n-tý, deň v mesiaci (31 = posledný), od–do.
  Z nich vznikajú **očakávané** pohyby: Potvrdiť (skutočná suma a deň) z nich spraví pohyb, Preskočiť = tentoraz nepríde.
  Omeškané sa ukazujú od začiatku položky, max. 90 dní dozadu (nová položka začína dnes, takže žiadne nemá).
- **Prehľad:** čistý majetok (osobné, firmy), zostatok za rok a prognóza na 6 mesiacov (pravidelné položky a pohyby zadané
  dopredu), mesiac s kategóriami, príjmy a výdavky za 6 mesiacov, najbližšie dva týždne. Každá peňaženka má svoj prehľad.
- **Touch ID:** zamknuté pri štarte, pri uspaní Macu alebo obrazovky a po 5 minútach na pozadí (⌃⌘L zamkne hneď). Heslo
  k Macu funguje, keď odtlačok nejde. Zámok chráni okno, MCP nie.
- **FinancieCore:** SQLite (`~/Library/Application Support/Financie/financie.sqlite`, WAL), sumy v centoch, EUR. Záloha
  do iCloud Drive › Financie › Záloha databázy raz denne (30 denných + 12 mesačných), Financie › Zálohovať teraz.
- **financie-mcp** (v `Financie.app/Contents/MacOS/`): stdio MCP nad tou istou databázou, funguje aj keď appka nebeží alebo
  je zamknutá. Nástroje: overview, accounts, categories, transactions, transaction_add/update/delete, transfer, reconcile,
  account_upsert, wallet_upsert, category_upsert, recurring_list/upsert/delete, expected, expected_confirm/skip,
  month_summary, forecast. Brain: `finance_overview` a riadok v rannom brífe (čo čaká a čo je splatné dnes či zajtra).
- URL: `financie://new`, `new-income`, `transfer`, `overview`, `transactions`, `waiting`, `recurring`, `account/<id>`.

Build: `./build-app.sh` → `~/Applications/Financie.app`. Testy: `swift test`. Ikona: `Icon/make-icns.sh`.
Vyskúšanie bez ostrých dát a bez zámku: `~/Applications/Financie.app/Contents/MacOS/Financie --demo /tmp/financie-demo`;
s `--snapshot <dir>` navyše vykreslí prehľady do PNG (svetlé aj tmavé) a skončí.
MCP: v `~/.claude.json` ako `financie` (Brain ho číta odtiaľ).

Ďalej: fáza 2 (neuhradené faktúry ako očakávaný príjem firmy, úhrady z Faktúr ako pohyby), fáza 3 (import výpisov
z bánk a párovanie), fáza 4 (rozpočty, rezerva na daň a DPH, investície).
