# Meetingy

Meetings in one window, in the series in Hangar (`com.lockedin.meetings`): what's coming up with a prep for each, and every
recorded meeting Brain imported from Fathom, read as sections.

- **Najbližšie:** meetings with other people in the next 14 days (all calendars), grouped by day. Opening one shows the
  people (with their Daktela contact), a join button for Meet / Zoom / Teams, the invitation's agenda without the boilerplate,
  and Brain's meeting prep: e-mails (open in Courier), WhatsApp, earlier meetings, notes and open Todoist tasks.
- **Nahrávky:** Fathom notes (10T, Kudosky, Súkromné) by month, searchable, with purpose, key takeaways, action items,
  next steps and topics; the transcript stays in the note (opens from the detail). Toolbar: open in Fathom, show in Finder,
  ask Brain for tasks.
- A recording can be moved to another business (toolbar or right click: Presunúť do) or deleted (Vymazať, Delete key):
  `brain meeting-move <path> <10t|kudosky|personal|other>` moves the note to that business's folder, `brain meeting-delete <path>`
  puts it in the Trash. Fathom import doesn't write either back.
- Data comes from Brain: `node ~/Developer/brain/src/cli.js meetings --days 365` and `meeting-prep <event id>`
  (`brain/src/meetings.js`). The last result is cached in `~/Library/Application Support/Meetings`.
- URLs: `meetings://upcoming`, `meetings://next` (the next meeting with its prep), `meetings://recordings`, `meetings://refresh`.
- `Meetings --snapshot <dir> [meetings.json]` renders the details to PNG (light and dark), for checking the design.
- Build and install: `./build-app.sh`. Icon: `Icon/make-icns.sh`.
