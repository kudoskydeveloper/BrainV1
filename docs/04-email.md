# E-mail cez Courier

Mail ide v Braine **iba cez Courier**, vlastného lokálneho klienta (`apps/Courier`). Courier sa pripojí cez IMAP a SMTP, poštu si
uloží do SQLite na Macu a cez `courier-mcp` ju sprístupní Claudovi. Nie je v tom žiadny server ani cloud.

## Inštalácia

```bash
cd ~/Developer/BrainV1/apps/Courier && ./build-app.sh
```

```bash
claude mcp add -s user courier -- ~/Applications/Courier.app/Contents/MacOS/courier-mcp
```

Potom v Courieri → Pridať účet. Nastavenia servera si zistí sám (autoconfig, ISPDB, MX). Heslo uloží do Keychainu (`com.lockedin.courier`).

## Heslá pre appky

Väčšina poskytovateľov nepustí bežné heslo cez IMAP. Treba vytvoriť **heslo pre aplikáciu**:

| Poskytovateľ | Kde |
|---|---|
| Gmail / Google Workspace | myaccount.google.com → Zabezpečenie → Dvojstupňové overenie (zapnúť) → Heslá aplikácií. Vo Workspace musí admin povoliť IMAP |
| iCloud | account.apple.com → Prihlásenie a zabezpečenie → Heslá pre aplikácie |
| Outlook / Microsoft 365 | account.microsoft.com → Zabezpečenie → Heslá aplikácií (365 firemný účet: admin musí povoliť IMAP/SMTP AUTH) |
| Seznam, Zoznam, Websupport, vlastná doména | bežné heslo do schránky, IMAP býva zapnutý |

## Ako to Claude používa

- čítanie: `courier.list_messages`, `search`, `thread`, `read_message`, `attachments`, `save_attachment`
- písanie: predvolene `draft` (koncept v Courieri s podpisom). Poslanie je `propose_send` → potvrdenie → `commit_mail`. Pri `send_at` správu
  pošle neskôr Courier sám (priečinok Na odoslanie)
- mazanie, presun a odhlásenie z newslettrov: vždy návrh a potom potvrdenie
- Brain z mailov skladá `meeting_prep`, `client`, `morning_brief`, Ľudí aj recapy z Fathomu

Ak chceš iného klienta, Brain sa dá prepojiť s akýmkoľvek mail MCP. Pravidlo „iba Courier“ je v `brain/src/registry.js` (`NEVER`, `NOT_ROUTED`)
a v inštrukciách v `brain/src/server.js`.

## Kalendár

Kalendár ide cez Apple Calendar (EventKit). Google, iCloud aj Exchange účty pridaj do macOS v Nastaveniach → Internetové účty a Brain ich uvidí
všetky. Predvolený kalendár pre nové udalosti je `calendar.default_calendar` v `brain.config.json`.
