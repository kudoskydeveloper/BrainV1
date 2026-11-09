# Časté problémy

| Problém | Riešenie |
|---|---|
| `claude mcp list` ukazuje brain ako ✗ failed | `node ~/Developer/brain/src/server.js` spusti ručne a pozri chybu. Najčastejšie chýba `npm ci` v `brain/` |
| Claude Desktop Brain nevidí | v `claude_desktop_config.json` musí byť plná cesta k `node` (`which node`) a k `server.js`, potom Desktop reštartuj |
| „Calendar helper didn't answer“ | `brain/tools/calendar/build.sh`, potom Súkromie → Kalendáre → povoliť Brain Calendar |
| Po každom builde sa appka pýta na prístupy znova | chýba certifikát Apple Development (návod v [05-appky.md](05-appky.md)) |
| `swift build` padá na `macOS 26` | treba macOS 26 a Xcode 26 (`sudo xcode-select -s /Applications/Xcode.app`) |
| WhatsApp a Safari sú prázdne | Full Disk Access pre appku, z ktorej Brain beží (Terminal, Claude, Brain) |
| Courier sa neprihlási | treba heslo pre aplikáciu, nie bežné heslo ([04-email.md](04-email.md)) |
| `semantic_search` nič nenájde | `ollama serve`, `ollama pull embeddinggemma`, potom v Claude `semantic_reindex` |
| Appka nevidí Brain | musí existovať `~/Developer/brain` (spraví ho `setup.sh`) |
| Brain app neodpovedá | `claude` v Termináli musí byť prihlásený. Skontroluj, že existuje `brain/brain-only.mcp.json` (vytvorí ho `setup.sh`) |
| Brain spomína služby, ktoré nemám (Daktela, Selleriz…) | sú to voliteľné integrácie, ktoré Brain bez servera preskočí. Vypneš ich v mape alebo cez `"off"` |
