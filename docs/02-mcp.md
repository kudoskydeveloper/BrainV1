# MCP: ako sa Claude napája na veci

**MCP (Model Context Protocol)** je štandard, cez ktorý Claude volá nástroje. MCP server je malý program alebo web endpoint, ktorý
povie „mám tieto nástroje s týmito parametrami“ a Claude ich potom volá. Funguje to ako USB pre AI: raz napíšeš server a ide v
Claude Code, Claude Desktop aj inde.

## Dva druhy serverov

| | stdio (lokálny) | HTTP (vzdialený) |
|---|---|---|
| Čo to je | program na tvojom Macu, Claude ho spustí a rozpráva s ním cez stdin/stdout | URL (`https://…/mcp`), prihlásenie väčšinou cez OAuth |
| Príklady | `brain`, `courier`, `scout`, `faktury`, `recepty` | Todoist, Notion, Linear, Gmail/Drive konektory, vlastné CRM |
| Dáta | ostávajú na Macu | idú do služby, ktorá ich má aj tak |

## Pridanie do Claude Code

```bash
claude mcp add -s user brain -- node ~/Developer/brain/src/server.js
```

```bash
claude mcp add -s user --transport http todoist https://ai.todoist.net/mcp
```

```bash
claude mcp list
```

- `-s user` znamená, že server platí vo všetkých projektoch (zápis do `~/.claude.json`). Bez neho platí len pre aktuálny priečinok.
- Premenné prostredia: `claude mcp add -s user meno -e API_KEY=… -- príkaz`. Kľúč sa uloží do `~/.claude.json`, nie do repozitára.
- Vzdialený server s OAuth sa prihlási pri prvom použití (`/mcp` v Claude Code).

## Pridanie do Claude Desktop

Nastavenia → Developer → Edit Config otvorí `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "brain": { "command": "/opt/homebrew/bin/node", "args": ["/Users/TVOJE_MENO/Developer/brain/src/server.js"] }
  }
}
```

Desktop potrebuje plnú cestu k `node` (zistíš ju cez `which node`) a k serveru. Po zmene ho reštartuj. Vzdialené servery pridáš v Desktope
cez Nastavenia → Connectors.

## Ako Brain nájde ostatné servery

`brain/src/registry.js` číta:
1. `~/.claude.json` → `mcpServers` (Claude Code, user scope) a profily `~/.claude-*`,
2. `~/Library/Application Support/Claude*/claude_desktop_config.json` a zapnuté rozšírenia (.mcpb),
3. `brain.config.json → remote` (HTTP servery, ku ktorým sa Brain prihlási sám cez OAuth: `node brain/src/cli.js connect <meno>`).

Lokálne (stdio) servery Brain spúšťa sám a po `idle_close_minutes` ich zavrie (`src/pool.js`). Claude ich nájde cez
`capabilities "todoist"` a zavolá cez `call`. Vďaka tomu stačí mať v Claude pripojený iba Brain.

## Ako napísať vlastný MCP server

Najrýchlejšie v Node so `@modelcontextprotocol/sdk` (pozri `apps/scout/src/index.js` alebo `brain/src/server.js`):

```js
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
const s = new McpServer({ name: "moj", version: "0.1.0" });
s.tool("ahoj", "Pozdraví", { meno: z.string() }, async ({ meno }) => ({ content: [{ type: "text", text: `Ahoj ${meno}` }] }));
await s.connect(new StdioServerTransport());
```

Swift appky majú MCP ako samostatný target (`Sources/<App>MCP/main.swift`), ktorý číta tú istú SQLite ako appka.
Stačí povedať Claudovi „sprav MCP server pre X podľa vzoru v apps/Recepty“.

## Kde hľadať hotové servery

- Claude Desktop → Connectors (oficiálne: Google, Notion, Linear, Todoist, Slack…)
- https://github.com/modelcontextprotocol/servers (referenčné servery)
- https://mcp.so a https://smithery.ai (katalógy komunitných serverov)
- Dokumentácia: https://modelcontextprotocol.io a https://docs.claude.com/en/docs/claude-code/mcp
