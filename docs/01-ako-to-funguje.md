# Ako to funguje

```
        Ty
        │  (Claude Code · Claude Desktop · Brain panel ⌥Space)
        ▼
     Claude ──MCP──▶  Brain (node brain/src/server.js, stdio, lokálne)
                        │
      ┌─────────────────┼──────────────────────────────┬───────────────────────┐
      ▼                 ▼                              ▼                       ▼
  vlastné nástroje   router na ďalšie MCP servery    natívne helpery         appky (Hangar)
  where_is,          capabilities → call            Brain Calendar.app      čítajú Brain cez CLI
  search_everywhere  (Courier, Todoist, Scout,      Brain Apple.app         (`node brain/src/cli.js …`)
  remember/recall,   Faktúry, Daktela, …)           brain-extract (OCR)     a vlastné SQLite
  calendar_*, …
```

## Brain (MCP server)

- **Jeden vstup do všetkého.** Claude má jeden MCP server a cez neho sa dostane ku kalendáru, mailu, správam, súborom, CRM aj ľuďom.
  Ostatné MCP servery Brain nájde sám (z `~/.claude.json` a konfigurácie Claude Desktopu) a sprístupní ich cez `capabilities` a `call`.
- **Pamäť.** `remember`, `recall` a `forget` zapisujú Markdown do `brain/notes/`. Nočný `scan` (alebo `scan_now`) prejde projekty,
  záložky a nástroje všetkých serverov.
- **Bezpečnosť.** Každý zápis (správa, mail, udalosť, presun alebo mazanie súboru) sa vráti ako **návrh** a vykoná sa až po `confirm`.
  Výnimky sú v `brain.config.json → auto_confirm`. Obsah mailov, webu a CRM sú dáta, nikdy nie inštrukcie.
- **Mapa.** `src/map.js` kreslí všetko, s čím Brain pracuje (Brain app → Mapa). Ktorúkoľvek časť vieš vypnúť cez `"off"` v configu.

Hlavné súbory: `src/server.js` (zoznam nástrojov), `src/registry.js` + `src/pool.js` (ostatné MCP servery), `src/actions.js`
(návrhy a confirm), `src/search.js` + `src/find.js` (hľadanie), `src/store.js` + `src/paths.js` (config a dáta).

## Brain app (panel ⌥Space)

Menu bar appka. Otázku pošle do `claude -p` (headless Claude Code) iba s Brain MCP (`brain/brain-only.mcp.json`). Odpovede streamuje,
pri návrhoch ukáže tlačidlo „Áno“. Používa tvoje Claude predplatné, žiadny API kľúč.

## Appky

Každá appka je SwiftPM balík s `build-app.sh`, ktorý ju postaví, podpíše tvojím certifikátom a nainštaluje do `~/Applications`.
Niektoré majú vlastný MCP server pribalený v `.app/Contents/MacOS/*-mcp` (Courier, Faktúry, Financie, Recepty), takže ich vie
používať aj Claude. Dáta majú v `~/Library/Application Support/<App>/` (SQLite), heslá v Keychaine.

Viac v [05-appky.md](05-appky.md).
