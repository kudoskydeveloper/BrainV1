# Faktúry

Lokálna fakturačná appka zo série `com.lockedin.*` (Brain, Courier, Fitness, Meetings, Hangar). Viac subjektov (firmy aj živnosti),
odberatelia, koncept → vystavená (nemenná) → dobropis, zálohové faktúry, PDF s QR kódom PAY by square, úhrady, MCP pre Brain.

- **FakturyCore**: SQLite (`~/Library/Application Support/Faktury/faktury.sqlite`, WAL) s triggermi, ktoré zamknú vystavené doklady
  a audit log; číselné rady per subjekt a rok (číslo až pri vystavení); DPH zo súčtu základov za sadzbu; kontrola náležitostí;
  PDF (SwiftUI → vektorové PDF, A4, viac strán); PAY by square 1.1.0 (systémová liblzma, overené proti knižnici `bysquare`);
  RegisterUZ + VIES na dohľadanie firiem; záloha do iCloud Drive › Faktúry (po každom vystavení a denne, 30 denných + 12 mesačných)
  a kópia PDF podľa subjektu a roka; export pre účtovníčku (PDF + CSV).
- **Faktury**: SwiftUI appka (bočný panel: doklady, subjekty, odberatelia, prehľad príjmov), editor so živým náhľadom PDF.
  URL: `faktury://new`, `new-proforma`, `unpaid`, `overdue`, `drafts`, `clients`, `overview`, `invoice/<id>`.
- **faktury-mcp** (v `Faktury.app/Contents/MacOS/`): stdio MCP nad tou istou databázou, funguje aj keď appka nebeží.
  Vystavenie dvojkrokovo `invoice_issue` (náhľad) → `commit_issue`; `invoice_send` robí len koncept e-mailu v Courieri.

Build: `./build-app.sh` → `~/Applications/Faktury.app`. Testy: `swift test`. Ikona: `Icon/make-icns.sh`.
Vyskúšanie bez ostrých dát: `~/Applications/Faktury.app/Contents/MacOS/Faktury --demo /tmp/faktury-demo`.
MCP: `claude mcp add -s user faktury -- ~/Applications/Faktury.app/Contents/MacOS/faktury-mcp` (Brain ho číta z `~/.claude.json`).
