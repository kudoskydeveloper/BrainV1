# Courier

Lokálny e-mailový klient zo série `com.lockedin.*` (Brain, MarketBar, Hangar). SwiftUI, Liquid Glass, žiadny server.

- **CourierCore**: autoconfig (autoconfig.<doména>, ISPDB, MX → ISPDB, odhad), vlastný IMAP klient (URLSessionStreamTask, SSL/STARTTLS),
  MIME parser, SQLite cache v `~/Library/Application Support/Courier/courier.sqlite`, heslá v Keychaine (`com.lockedin.courier`).
- **Courier**: sidebar (nástenka projektov, schránky, priečinky), zoznam správ ako chat, čítanie HTML bez JS a bez vzdialeného obsahu.
- **courier-mcp**: stdio MCP (`Courier.app/Contents/MacOS/courier-mcp`). Číta priamo zo SQLite; na sieť (sťahovanie tela, sync)
  sa pýta bežiacej appky cez `courier.sock`. Nástroje: accounts, folders, projects, list_messages, search, read_message, sync, open_in_courier.

Build: `./build-app.sh` → `~/Applications/Courier.app`. iPhone (CourierMobile): `./build-ios.sh` do simulátora, `--mac-data` skopíruje poštu z Macu. Testy: `swift test` (živý autoconfig: `COURIER_LIVE=1 swift test --filter Live`).

Hotové: autoconfig, viac účtov, priečinky (IMAP special-use), vlákna, celá história, projekty so schránkami v lište
(drag & drop, Nezaradené), lokálny ticketing (stav + štítky, auto-reopen), composer (nová, odpoveď, všetkým, preposlať, Cc/Bcc,
prílohy, zrušiť odoslanie 10 s, naplánované odoslanie, podpisy text/HTML s predvoleným na účet, našepkávanie z Kontaktov
a histórie, úprava konceptov a naplánovaných správ), mazanie do Koša / trvalo v Koši, archivácia, presun, prílohy
(hľadanie v celej histórii, Quick Look, uloženie, prehľad), MCP: accounts, folders, projects, list_messages, search,
read_message, thread, set_ticket, draft (predvolene), send (náhľad → confirm), attachments, save_attachment, signatures,
sync, open_in_courier.

Fáza 2 hotová: inteligentné skupiny (Ľudia, Notifikácie, Newslettre, Pozvánky, Faktúry a platby; v zozname zbalené do jedného
riadku, filtre hore, zaradenie odosielateľa ručne), notifikácie (predvolene Ľudia + Pozvánky) a odznak v Docku, kontrola Doručených
každú minútu, Hangar (courier://inbox, courier://compose), MCP: groups, set_sender_group, mark_read, archive,
propose_send → commit_mail, propose_delete → commit_trash, propose_move → commit_move, propose_unsubscribe → commit_unsubscribe; Brain hľadá a ukladá poštu z Courieru
(search_everywhere, meeting prep, save_email "courier:<id>", index podľa významu).

Zostáva: okamžité doručenie cez IMAP IDLE (teraz kontrola každú minútu), OAuth (zatiaľ netreba), formátovaný text v composeri.

Odhlásenie z newslettrov: z hlavičiek List-Unsubscribe / List-Unsubscribe-Post (ukladajú sa do cache; staršie správy ich dotiahnu
z .eml alebo jedným IMAP FETCH). Poradie: jedným klikom (RFC 8058, POST) → odhlasovací e-mail z účtu → len web (otvorí sa prehliadač).
Po odhlásení sa odosielateľ zaradí do Newslettrov a jeho správy z Doručenej pošty sa dajú archivovať. Tlačidlo Odhlásiť je v detaile
hromadného mailu na Macu aj v iPhone appke, vždy s potvrdením.
