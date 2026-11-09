# Herald

LinkedIn network and outreach across projects, in one window. Part of the `com.lockedin.*` family in Hangar (`com.lockedin.herald`).
The successor of the KuMCP extension page: not just for Kudosky, but for any project (Kudosky, 10T, …).

- **Projekty:** each project has a playbook (`~/.herald/playbooks/<id>.md`) and stages: Lead → Oslovený → Follow-up →
  Neskôr / Nie / Meeting. One person can be in several projects with a stage in each. Nobody picked = the pipeline at a glance.
  Stages and `<project>-<stage>` tags stay in sync both ways, so playbooks that say "tag kudosky-meeting" still work.
- **Správy:** Čaká na teba (they wrote last, within a month; also the red badge on the Hangar tile), Čakáš na nich (you wrote
  last 3–60 days ago), all conversations. Live from Beeper through Brain (`brain linkedin-inbox`, matched to connections by
  LinkedIn profile id) over the history the linkedin server downloaded earlier; Herald never downloads messages through
  Chrome. Replies go through Beeper ("Otvoriť Beeper") or Claude (Brain's `messenger_send`, network linkedin).
- **Čaká na teba** shows a conversation only while it isn't closed: Nekontaktovať, every project at stage "no", only a 👍 or a
  short thanks, or **Vybavené** (button in the last message card, right-click on a conversation, or several at once). A
  Vybavené conversation comes back when that person writes again. The same list is `linkedin_inbox` for Claude, and
  `linkedin_inbox_done` marks Vybavené from there.
- **Kontakty:** all, talked before, never talked, Nekontaktovať (`do-not-contact`, global for every project).
  Filters: role, seniority, country (guessed from headlines and the country sync). Sort: last message, newest, name.
- **Rast siete:** Prospekti (2nd/3rd degree people search, toolbar "Hľadať ľudí", optionally straight into a project as
  leads), invites sent from Herald, pending invites (oldest first, withdraw several at once).
- **Detail:** stage per project, last message, note, tags, Nekontaktovať. ⌘-click several people to move them to a stage,
  tag them or withdraw invites in one go.
- **Export CSV** of the shown list (or the picked people), with a column per project.

## How it works
Herald is only the window. The data and LinkedIn access are in `~/Developer/linkedin-mcp`: its server answers on
`127.0.0.1:47332` (`server/src/ui-server.js`), and the Chrome extension does the LinkedIn work in your logged-in browser.
Reading needs nothing; changes send the local secret (`~/.herald/secret`) in `x-herald-secret`. The server runs from login (`linkedin-mcp/scripts/install-agent.sh`); when nothing answers,
Herald starts it itself, so it works without an open Claude session. The last state is cached in
`~/Library/Application Support/Herald`, so the window opens with data right away. ⌘R reloads.

Nothing is sent to anyone without your click: an invite shows the person and the exact note first, withdrawing asks first,
and messages are written in Beeper or through Claude (`linkedin_propose_message` → approve → commit).

- URL: `herald://reply`, `herald://waiting`, `herald://prospects`, `herald://pending`, `herald://all`,
  `herald://project/<id>`, `herald://refresh`. Hangar uses them.
- `Herald --snapshot <dir> [state.json]` renders rows and details to PNG (light and dark).
- Build and install: `./build-app.sh`. Icon: `Icon/make-icns.sh` (raspberry → wine red, the herald's standard: a pole, a swallow-tailed banner and a ring for the seal; sketch in `Hangar/icon-ideas/herald-b-zastava.svg`).
