# Recepty

Recepty s výživovými hodnotami, režimom varenia, jedálničkom a denníkom, zo série `com.lockedin.*` (v Hangar).

- **Z fotky:** odfotená strana kuchárky, kartička, rukopis alebo screenshot (viac strán v poradí): z Fotiek, zo súboru,
  pretiahnutím alebo ⌘V. Model sa pozerá priamo na fotky (prečíta aj rukopis a starý pravopis), OCR z Brainu
  (`~/Developer/brain/tools/extract/brain-extract`, Vision, lokálne) mu pomáha. Cez Brain: photos_search → photos_export →
  `recepty.recipe_import` s `images`.
- **Archív originálov:** fotky, z ktorých recept vznikol, ostanú pri ňom v plnej kvalite
  (`~/Library/Application Support/Recepty/originaly`) s prečítaným textom. Karta Originál na stránke receptu, prehliadač so
  zväčšením a textom, ktorý sa dá opraviť; fotky sa dajú pridať aj k existujúcemu receptu. Recept bez vlastnej fotky jedla
  ukazuje ako obrázok prvú fotku originálu.
- **Od koho:** pri recepte (babka Mária, teta Eva, kuchárka); z fotky ho model zistí sám, keď je tam napísaný. Sekcia
  Od koho v bočnom paneli, hľadanie a `recipes` s `author` v MCP.
- **Pridanie receptu:** odkaz na stránku (číta jej schema.org Recipe, ktoré má väčšina stránok s receptami) alebo ľubovoľný
  text (recept bez týchto dát, vložený text, poznámka) cez model. Recept v inom jazyku sa preloží do slovenčiny a jednotky
  sa prevedú na metrické. Fotka sa stiahne do `~/Library/Application Support/Recepty/images`.
- **Výživa:** každá surovina → potravina z pribalenej databázy USDA FoodData Central (SR Legacy + Foundation, ~8 100 potravín,
  `Resources/foods.sqlite`, staviaš ju `Tools/build-foods.py`) alebo z Open Food Facts (balené výrobky, aj slovenské).
  Dva volania modelu na recept: (1) riadky → názov, množstvo, gramy, anglický dopyt; (2) výber zhody z kandidátov alebo
  odhad na 100 g. Model ide cez `claude` CLI s prihlásením ako Brain (`RECEPTY_MODEL`, predvolene sonnet); odpovede sa
  cachujú v databáze. Surovina sa dá opraviť kliknutím (hľadanie v USDA a OFF, gramy, „Nepočítať“); ručne vybranú potravinu
  si appka zapamätá pre rovnaký názov nabudúce.
- **Stav suroviny:** z databázy (zelená), odhad (oranžová), upravené ručne (modrá), nepočíta sa (sivá), nenájdené (červená).
- **Kalkulačka porcií:** − / + pri surovinách prepočíta množstvá aj gramy; výživa na porciu, na 100 g a za celé jedlo.
  „Hotové jedlo (g)“ v úprave = odvážený hrniec; s ním je zápis „zjedol som 340 g“ presný.
- **Režim varenia:** vlastné okno, krok po kroku veľkým písmom (← → alebo medzerník), suroviny na odškrtnutie, časovače
  z textu kroku („varíme 20 minút“) so zvukom a notifikáciou, displej nezhasne.
- **Jedálniček** (týždeň), **Denník** (čo som zjedol, súčty, 14 dní v grafe), **Nákup** (suroviny naplánovaných receptov
  od dnes sčítané; Kopírovať).
- **recepty-mcp** (v `Recepty.app/Contents/MacOS/`): stdio MCP nad tou istou databázou, v `~/.claude.json` ako `recepty`
  (Brain ho volá cez `call`). Nástroje: recipes, recipe (servings = prepočet), recipe_import, recipe_update, recipe_analyze,
  recipe_delete, food_search, meal_log, meals, meal_delete, plan, plan_add, plan_remove, shopping_list. Appka zmeny
  z MCP zachytí sama (PRAGMA data_version každé 2 s).
- **URL:** `recepty://new`, `plan`, `log`, `shopping`, `recipe/<id>`, `cook/<id>`. Hangar má akcie Nový recept, Jedálniček, Nákup.

Databáza: `~/Library/Application Support/Recepty/recepty.sqlite` (WAL), `RECEPTY_DB` ju presmeruje.
Build: `./build-app.sh` → `~/Applications/Recepty.app`. Testy: `swift test`. Ikona: `Icon/make-icns.sh`.
Vyskúšanie bez ostrých dát a bez modelu: `~/Applications/Recepty.app/Contents/MacOS/Recepty --demo /tmp/recepty-demo`;
s `--snapshot <dir>` navyše vykreslí stránky do PNG (svetlé aj tmavé) a skončí.
