#!/bin/zsh
# Brain kit – inštalácia na Mac. Spusti z koreňa repozitára: ./setup.sh   (alebo ./setup.sh --apps na build všetkých appiek)
# Nič nemaže. Existujúce priečinky v ~/Developer nechá tak a len upozorní.
set -u
KIT="$(cd "$(dirname "$0")" && pwd)"
DEV="$HOME/Developer"
ok()   { print -P "%F{green}✓%f $1"; }
warn() { print -P "%F{yellow}!%f $1"; }
fail() { print -P "%F{red}✗%f $1"; }

print -P "%BBrain kit setup%b ($KIT)\n"

# 1) Požiadavky -------------------------------------------------------------------------------------------------
v=$(sw_vers -productVersion); [[ ${v%%.*} -ge 26 ]] && ok "macOS $v" || warn "macOS $v – appky potrebujú macOS 26 (Tahoe), Brain server pobeží aj na staršom"
command -v node >/dev/null && ok "Node $(node -v)" || { fail "Chýba Node.js 20+:  brew install node"; exit 1; }
command -v swift >/dev/null && ok "Swift: $(swift --version 2>&1 | head -1 | sed -E 's/.*Swift version ([0-9.]+).*/\1/')" \
  || warn "Chýba Swift/Xcode (xcode-select --install alebo Xcode 26 z App Store) – bez neho sa nepostavia appky ani helpery"
command -v python3 >/dev/null && ok "Python $(python3 -V | cut -d' ' -f2)" || warn "Chýba python3 (market-alerts, časť Brainu)"
command -v claude >/dev/null && ok "Claude Code CLI" || warn "Chýba Claude Code CLI:  npm install -g @anthropic-ai/claude-code  (alebo curl -fsSL https://claude.ai/install.sh | bash)"
command -v ollama >/dev/null && ok "Ollama (vyhľadávanie podľa významu)" || warn "Voliteľné: Ollama na semantic_search:  brew install ollama && ollama pull embeddinggemma"

# 2) Cesty, ktoré appky očakávajú (~/Developer/brain, market-alerts, scout) ----------------------------------------
mkdir -p "$DEV"
link() { local name=$1 target=$2
  if [[ -L "$DEV/$name" ]]; then ln -sfn "$target" "$DEV/$name"; ok "~/Developer/$name → $target"
  elif [[ -e "$DEV/$name" ]]; then warn "~/Developer/$name už existuje (nechávam ho, appky budú používať ten)"
  else ln -s "$target" "$DEV/$name"; ok "~/Developer/$name → $target"; fi }
link brain "$KIT/brain"
link market-alerts "$KIT/apps/market-alerts"
link scout "$KIT/apps/scout"
BRAIN="$DEV/brain"

# 3) Brain server -------------------------------------------------------------------------------------------------
(cd "$KIT/brain" && npm ci --silent) && ok "Brain: npm závislosti" || fail "npm ci zlyhalo v brain/"
(cd "$KIT/apps/scout" && npm ci --silent 2>/dev/null) && ok "Scout: npm závislosti" || warn "Scout: npm ci zlyhalo (voliteľné)"
mkdir -p "$KIT/brain/data" "$KIT/brain/notes"
# Brain app spúšťa `claude -p` len s Brainom: brain-only.mcp.json (generovaný, v .gitignore)
sed "s#__BRAIN_DIR__#$BRAIN#" "$KIT/brain/brain-only.mcp.example.json" > "$KIT/brain/brain-only.mcp.json" && ok "brain-only.mcp.json"
(cd "$KIT/brain" && npm test 2>&1 | grep -qE "^# fail 0") && ok "Brain: testy prešli" || warn "Brain: niektoré testy neprešli (npm test v brain/)"

# 4) Natívne helpery Brainu (Kalendár/Pripomienky, Apple appky, OCR) -------------------------------------------------
if command -v swiftc >/dev/null; then
  for t in calendar apple extract; do (cd "$KIT/brain/tools/$t" && ./build.sh >/dev/null 2>&1) && ok "helper tools/$t" || warn "helper tools/$t sa nepostavil"; done
fi

# 5) Registrácia MCP v Claude Code -----------------------------------------------------------------------------------
if command -v claude >/dev/null; then
  if claude mcp get brain >/dev/null 2>&1; then ok "MCP 'brain' už je v Claude Code"
  else claude mcp add -s user brain -- node "$BRAIN/src/server.js" >/dev/null && ok "MCP 'brain' pridaný do Claude Code (user scope)"; fi
fi

# 6) Appky (voliteľné, trvá to) --------------------------------------------------------------------------------------
if [[ "${1:-}" == "--apps" ]]; then
  mkdir -p "$HOME/Applications"
  for a in Hangar BrainApp Courier Ludia Meetings Fitness Recepty Home Herald Obchody Faktury Financie MarketBar scout/app; do
    print -P "%B→ $a%b"; (cd "$KIT/apps/$a" && ./build-app.sh >/tmp/brainkit-build-${a//\//-}.log 2>&1) \
      && ok "$a" || fail "$a – log: /tmp/brainkit-build-${a//\//-}.log"
  done
  command -v claude >/dev/null && for m in courier faktury financie recepty; do
    app=$(ls -d "$HOME/Applications/"*.app 2>/dev/null | while read x; do [[ -x "$x/Contents/MacOS/$m-mcp" ]] && echo "$x"; done | head -1)
    [[ -n "$app" ]] && ! claude mcp get $m >/dev/null 2>&1 && claude mcp add -s user $m -- "$app/Contents/MacOS/$m-mcp" >/dev/null && ok "MCP '$m' pridaný"
  done
  command -v claude >/dev/null && ! claude mcp get scout >/dev/null 2>&1 && claude mcp add -s user scout -- node "$DEV/scout/src/index.js" >/dev/null && ok "MCP 'scout' pridaný"
fi

print -P "\n%BĎalej:%b otvor docs/00-zaciatok.md, alebo v Claude Code napíš:  %Bnastav mi Brain podľa CLAUDE.md%b"
