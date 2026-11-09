# Fitness

My training and food in one window: Hevy (strength, body weight), Strava (every activity) and MyFitnessPal (calories, macros),
with charts. Part of the series in Hangar (`com.lockedin.fitness`).

- Data comes from Brain: `node ~/Developer/brain/src/cli.js fitness --days 30` (`brain/src/fitness.js`, also the MCP tool
  `fitness_overview`). Brain holds the Hevy key, the Strava login and routes to the `myfitnesspal` MCP server.
- The last overview per period is cached in `~/Library/Application Support/Fitness`, so the window opens with data right away.
- Sidebar: Prehľad, one page per sport (strength, bicycle, running, swimming, walking, other; only those with activities in the
  period), Výživa, Váha. Strength lists every Hevy exercise of the last year with its last and best set, estimated 1RM
  (Epley), a trend line and the change; an exercise opens to its chart over time (1RM, top weight, volume, reps) and history.
- Period: week / month / 3 months / year (toolbar). ⌘R refreshes. A source that fails shows a note; the rest still shows.
- `Fitness --snapshot <dir> [overview.json]` renders every page to PNG (light and dark), for checking the design.
- URLs: `fitness://overview` (open the window), `fitness://refresh` (load now). Hangar uses them.
- Build and install: `./build-app.sh`. Icon: `Icon/make-icns.sh`.
