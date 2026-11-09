# Súkromie a dáta

## Čo v tomto repozitári NIE JE

Žiadne poznámky, správy, kontakty, maily, faktúry, finančné údaje, obchody, kľúče, tokeny, heslá, cesty k cudziemu počítaču ani história gitu
pôvodných projektov. Mená, IČO, IBAN a adresy v testoch a ukážkach sú vymyslené (napr. `Ján Vzor`, `hello@firma1.example`,
vzorový IBAN `SK31 1200 0000 1987 4263 7541`, ktorý sa bežne používa v príkladoch).

## Kde sú tvoje dáta po inštalácii

| Čo | Kde |
|---|---|
| Brain: cache, logy, návrhy, tokeny (Beeper, Strava, Hevy, OAuth) | `brain/data/` (v .gitignore) |
| Brain: čo si mu povedal | `brain/notes/` (v .gitignore) |
| Tvoje údaje (mená, maily, domény) | `brain/brain.config.json`. **Po vyplnení ho necommituj** (`git update-index --skip-worktree brain/brain.config.json`) |
| Appky | `~/Library/Application Support/<App>/` (SQLite) |
| Heslá k mailom, iDoklad | Keychain |
| Fathom, Alpaca kľúče | `~/.config/fathom/`, `~/.config/market-alerts/keys.env` |
| MCP konfigurácia s kľúčmi | `~/.claude.json`, `~/Library/Application Support/Claude/claude_desktop_config.json` |

## Čo odchádza z Macu

- To, čo Claude pri odpovedi prečíta, ide do Anthropicu, rovnako ako pri bežnom chate s Claudom. Brain posiela iba výsledky, ktoré si Claude vyžiada.
- Volania API služieb, ktoré si sám pripojil (Todoist, Fathom, Strava…).
- Home synchronizuje domácnosť s tvojím Supabase projektom.
- Embeddingy (Ollama), OCR (Vision) a indexy bežia lokálne.

## Pred každým pushom

```bash
git status --short && git diff --cached --stat
```

Ak tam vidíš `data/`, `notes/`, `.sqlite`, `keys.env` alebo vyplnený `brain.config.json`, zastav sa.
