# Plan

## Goal

A menu bar app that runs at login, watches the macOS unified log, and keeps a
searchable history of:

- **Sensor sessions:** which app used the camera, microphone, screen recording
  or location, from when to when.
- **Permission checks:** which app asked tccd for a protected resource (folders,
  Full Disk Access, contacts, screen capture and so on), and whether it was allowed.
- **Screen locks:** when the screen was locked, to flag sensor use while nobody was at the Mac.
- **Admin rights:** which app or service authd granted an authorization right
  (admin password, software install, changing system daemons).

## Data sources (verified 2026-10-09, macOS 27.0.1)

One `log` process watches every source with a single combined predicate, so
events arrive in order.

### Control Center snapshots

```
Active activity attributions changed to ["cam:com.microsoft.teams2", "mic:com.microsoft.teams2"]
Active activity attributions changed to ["loc:System Services"]
Active activity attributions changed to []
```

- The payload is a JSON array of `tag:app`. The app is a bundle ID, or a display
  name when there is no bundle (System Services).
- Tags seen: `cam`, `mic`, `scr`, `loc`. Unknown future tags are kept as-is.
- The same entry can appear twice in one snapshot, so treat it as a set.
- Each line is the full current state. Diffing consecutive snapshots gives
  start and stop events.

### tccd permission checks

Each check is three lines that share `msgID` within one tccd process. There is
a system tccd and a per-user tccd, so the key is `(tccd pid, msgID)`.

```
AUTHREQ_CTX: msgID=47863.1, function=TCCAccessRequest, service=kTCCServiceAddressBook, preflight=yes, ...
AUTHREQ_ATTRIBUTION: msgID=47863.1, attribution={responsible={TCCDProcess: identifier=..., pid=..., ..., binary_path=...}, accessing={...}, requesting={...}, },
AUTHREQ_RESULT: msgID=47863.1, authValue=2, authReason=11, ...
```

- `authValue`: 0 denied, 1 unknown, 2 allowed, 3 limited.
- `preflight=yes` means "do I have permission?" without an access attempt.
  About 90% of checks are preflight.
- Volume is high: about 4,000 checks in 3 hours on the dev Mac. The app stores
  daily aggregates, not raw rows.

### Screen lock (loginwindow)

```
-[SessionAgentNotificationCenter sendDistributedNotification:object:] | sendDistributedNotification: com.apple.screenIsLocked, with object:501
-[SessionAgentNotificationCenter sendDistributedNotification:object:] | sendDistributedNotification: com.apple.screenIsUnlocked, with object:501
```

- The object is the user ID of the session. Lines for another user (Fast User
  Switching) are ignored.
- Lock and unlock came in clean pairs over 3 days on the dev Mac (about 20 lines).
  `-[LWScreenLock setScreenIsLocked:] ... setting to 1` says the same without the user ID.
- A Mac that shuts down while locked never logs the unlock. A lock still open
  from before the last boot (`kern.boottime`) is closed at the boot time.
- Adds about 20% to the time of a `log show` catch-up (17s to 21s for 12 hours).

### Admin rights (authd)

```
Succeeded authorizing right 'system.privilege.admin' by client '/usr/libexec/mdmclient' [7788] for authorization created by '/usr/libexec/mdmclient' [7788] (13,0) (engine 1358)
```

- Paths, not bundle IDs, both in clear text. Paths can hold spaces (`Software Update.app`),
  so a path ends at the `' [` before its pid.
- The creator is the app to blame (Software Update: the notification manager asks, the daemon
  works), the client is shown as "via" when it differs.
- `system.login.*` is skipped: loginwindow takes `system.login.screensaver` on every password unlock.
- Rights whose rule class is `allow` (`system.burn`, `system.hdd.smart`) are skipped: any
  process gets them without asking, so they are not admin rights. `AuthorizationRightGet`
  reads the rule without root (`AdminRight.isOpenToEveryone`).
- Checked end to end on 2026-10-10 with a test binary in an `Applications` folder: grant
  logged, stored, notification presented about 0.3s later.
- Only grants are logged with the right and client. A refusal is just
  `Fatal: authorization denied (...) (engine N)`, so denials are not recorded.
  `Process /path (PID N) evaluates N rights ... (engine N, token N): ( "right" )` (Info level)
  names the process and right and shares the engine number, but appears only for some
  clients (about 7 a day against about 25 grants), so it cannot back a denial record.
  Not checked: what a user cancelling a password prompt logs (no cancel in 7 days of logs).
- A grant the user approved in a password or Touch ID prompt has extra lines in the same
  engine before the `Succeeded` line (checked 2026-10-10 with `security authorize -u -e system.privilege.admin`):
  `engine 1593: running mechanism builtin:authenticate (1 of 3)` and
  `UID 501 authenticated as user pawisoon (UID 501) for right 'system.privilege.admin'`.
  Silent grants (mdmclient, Software Update) have neither. Not used yet: it could mark
  grants that asked the user.
- About 25 grants a day on the dev Mac, mostly `mdmclient` and Software Update.
  Adds roughly 10 to 25% to the time of a `log show` catch-up (noisy: 35 to 44s for 12 hours).
- sudo goes through PAM, not authd, so it is not in here.

### Framing

- Use `--style ndjson`. `log stream` prints a plain-text header line first.
  `log show` ends with a `{"count":N,"finished":1}` object. Skip any line that
  is not a JSON object with an `eventMessage`.
- Timestamps look like `2026-10-08 00:11:56.880495+0200` (microseconds, numeric zone).

## Architecture

```
AppAlibi/                 SwiftUI menu bar app (thin UI layer)
AlibiKit/                 Swift package, all logic, unit-tested with `swift test`
  LogEntry                NDJSON line decoding, timestamp parsing
  LogPredicates           the one place that knows Apple's message formats
  ControlCenterParser     snapshot line -> Set<Attribution>
  ScreenLockParser        loginwindow line -> locked or unlocked (ScreenLock.swift)
  AdminRightParser        authd grant line -> AdminRightEvent (AdminRights.swift)
  SessionTracker          snapshot diff -> started / ended events
  TCCCorrelator           CTX + ATTRIBUTION + RESULT -> TCCAccessEvent
  EventProcessor          LogEntry stream -> domain events (pure, testable)
  EventStore              SQLite (system libsqlite3, no dependencies)
  AlertPlanner            stored batch -> notifications worth posting (fresh events only)
  CSVExport               sessions or permission rows -> RFC 4180 CSV
  ActivityReport          day or week summary: per-app time, hourly or daily bars, permission checks
  ReportSchedule          when the daily or weekly summary notification is due
  LogReader               runs /usr/bin/log, yields batches of LogEntry
  Collector               actor: catch-up with `log show`, then `log stream`
```

### Collector lifecycle

1. Restore the tracker from sessions that are still open in the database, and
   the lock state from a lock that is still open. A lock open from before the
   last boot is closed first. A database made before a source existed gets one
   import of that source's lines before its checkpoint (`meta.screen_locks_imported`,
   `meta.admin_rights_imported`, see `EventStore.HistorySource`).
2. Start `log stream` first, so nothing is missed while catching up.
3. Run `log show --start <last processed timestamp>` (first launch: last 3 days)
   and process it.
4. Drain the stream, skipping entries at or before the last processed timestamp.
5. If the stream process exits, restart it after a short delay and catch up again.

Each batch is written in one SQLite transaction together with the new
"last processed" timestamp, so a crash never double-counts or skips.

### Storage

`~/Library/Application Support/AppAlibi/alibi.sqlite`, WAL mode.

| Table | Contents |
|---|---|
| `sessions` | id, sensor, app, started_at, ended_at (NULL while active) |
| `tcc_access` | day, service, app, accessor, binary_path, auth_value, preflight, count, first_seen, last_seen |
| `screen_locks` | id, locked_at, unlocked_at (NULL while locked) |
| `admin_rights` | day, right_name, app (creator path), client (path), count, first_seen, last_seen |
| `meta` | last_processed timestamp, screen_locks_imported, admin_rights_imported |

Retention (Settings, "Keep history": Forever by default, or 1, 3, 6 or 12 months)
deletes closed sessions and locks that ended before the cutoff, and permission
and admin rows by day. It runs at launch, every 6 hours, and when the setting changes.
Shortening it asks first. The checkpoint stays, so nothing is imported again.

### UI

- **Menu bar icon:** an eye, filled while camera, mic or screen recording is active.
- **Menu bar panel:** status, "Active now", the last few sessions, Open History, Settings, Quit.
- **History window**, four tabs:
  - *Summary:* Day or Week, laid out like Screen Time: total time with camera,
    mic or screen on, a bar per hour or day, apps by time, then protected data
    per app. A call with camera and mic on counts once (spans are merged).
  - *Sensors:* table of sessions with app icon, sensor, start, duration. Filter by sensor and app.
    A lock icon marks sessions that ran at least 5 seconds while the screen was
    locked; the "While locked" filter shows only those.
  - *Permissions:* daily aggregates with app, service, result, count, last seen.
    Apple system processes and preflight checks are hidden by default.
  - *Admin:* daily aggregates of granted admin rights with app, right, count, last seen.
    Apps scope by default, so a normal Mac shows nothing until an installer asks.
  - *Export:* Sensors and Permissions export their current filters, without the
    table's row limit, as CSV (button, or File > Export as CSV…, Command-E).
    Times are ISO 8601 with the local offset. Cells that start with `= + - @` get a
    leading apostrophe, because app names come from whoever built the app and a
    spreadsheet would run them as formulas.
- **Settings:** launch at login, show location, notifications, reveal database, delete history.
- **Notifications** (all off by default). The welcome tour has a page with a
  "Turn On Notifications" button: it asks macOS for permission and, if granted,
  turns on first-use sensor alerts, the locked-screen alert and the daily summary. Settings asks too, the
  first time any notification is switched on.
  - camera, mic or screen started by an app: first use per app and sensor, or every session.
    Camera and mic from one app in one batch are one notification. Restarts inside
    the merge gap stay quiet.
  - first real (not preflight) check by an app for a TCC service.
  - use while the screen was locked: one notification on unlock, never while
    locked (a lock-screen banner can be read by anyone at the Mac). It lists camera,
    mic and screen use inside the lock, system services included (Screen Sharing
    on a locked Mac is the point), location left out. Less than 5 seconds of overlap
    does not count: an app letting go as the screen locks, or starting as you unlock.
    Clicking it opens Sensors with the "While locked" filter on.
  - daily and weekly summary at a chosen time (default 18:00, weekly on Friday).
    A timer checks every minute and on wake, so a Mac asleep at that time gets it
    on wake if within 6 hours.
  - an app (not a system service) granted an admin right: every time, one
    notification per app and batch listing its rights. Off by default and not
    switched on by the welcome tour.
  - Events older than 2 minutes never notify, so the catch-up at launch is silent.
  - Clicking a notification opens the matching history tab.

## Decisions

- **macOS 15+** for the app (scene launch behaviors), SwiftUI `MenuBarExtra` and `@Observable`.
- **Menu bar or Dock, never neither**, same rule as ZuckOff. Dragging the icon out of the menu bar switches to Dock.
- **No third-party dependencies.** SQLite through the system library instead of GRDB.
- **Not sandboxed.** The sandbox blocks spawning `/usr/bin/log`. Ships with
  Developer ID and notarization, outside the Mac App Store.
- **Project generated with XcodeGen** from `project.yml`. Xcode's own MCP bridge
  (`xcrun mcpbridge`, configured in `.mcp.json`) handles builds and previews
  once Xcode has the project open. It has no project-creation tool.
- Bundle ID `com.szydlowsky.AppAlibi`, team `297W77MNZY`.
- **English and Polish.** String catalogs in the app and in AlibiKit (sensor,
  permission and result names live there and are used by the CSV export too).
  Polish was translated with DeepL and edited by hand. Counts are written as
  "Label: N" so no Polish plural variations are needed.

## Milestones

1. **M1 Core (done 2026-10-09):** AlibiKit parsers, tracker, correlator, store,
   collector, 27 unit tests built from real log lines, `alibi-probe` CLI.
2. **M1 App (done 2026-10-09):** menu bar panel, history window, settings.
   Verified against the real log: the app recorded Teams camera and mic calls,
   a screenshot, and about 19,000 permission checks from the last 3 days.
   The UI has not been reviewed visually yet.
2b. **M1.5 (done 2026-10-09):** apps-versus-system filter (history scope picker, menu
   shows apps only by default), menu bar or Dock presentation, first-run welcome tour.
   Window handling and onboarding ported from ZuckOff's macOS target. Minimum macOS raised to 15.
3. **M2 Polish:** app icon (done 2026-10-09, `design/AppIcon.svg`, rendered by
   `design/render-icon.sh`), notifications and daily or weekly summaries (done 2026-10-09),
   Summary tab (done 2026-10-09). Onboarding version 2 adds the notifications page.
   Alert for use while the screen is locked, CSV export, data retention setting
   (done 2026-10-09). Not checked on a real lock yet: the unlock notification, and
   how a remote Screen Sharing session is attributed in `scr`.
3b. **M2.5 Speed:** tab switching off the main thread and kept warm (see "Speed" below).
   Built 2026-10-12, not timed yet.
3c. **M2.6 AI clients:** AI tab, Full Disk Access holders seen, mouse and keyboard control from
   the log (see "AI clients" and "Full Disk Access" below). Input watcher later, opt-in.
4. **M3 Ship:** Developer ID signing, notarization, Sparkle updates, website on appalibi.com.
5. **Later:** Endpoint Security extension for real file access history.

## Coverage review (2026-10-10, macOS 27.0.1)

Control Center logged only `cam`, `mic`, `scr` and `loc` in 7 days. tccd logged 26
services in 3 days. `Ubiquity`, `Willow`, `VoiceBanking`, `WebBrowserPublicKeyCredential`
and `PhotosAdd` had no display name and now do, along with other known services
not yet seen here.

Automation (`AppleEvents`) records the sender only. No AppleEvents check appeared in
3 days, and `AUTHREQ_CTX` redacts `daemon_dict`, so the target app is probably not logged.

Candidate new sources, best first:

1. **Admin authorizations** (`process == "authd"`): done 2026-10-10, see "Admin rights (authd)" above.
2. **Login items and background tasks** (`subsystem == "com.apple.backgroundtaskmanagement"`):
   `registerLaunchItem: ... name=X, type=...` has the name in clear, but some lines
   redact the bundle ID. About 100,000 lines a day, so the predicate must be tight.
3. **Remote access:** Screen Sharing (`screensharingd`) and SSH (`sshd-session`).
   No lines captured yet. Needs a test session.
4. **Touch ID and passkey prompts** (`com.apple.LocalAuthentication`): about 38,000
   lines a day, attribution and redaction not checked.
5. **System extension installs** (`sysextd`): rare, format not captured.

Not possible from the log: clipboard reads by app (only Biome noise), ongoing keyboard
monitoring or Accessibility use (only the tccd check), keychain reads (too noisy).
Each new source slows the `log show` catch-up, so measure with `alibi-probe`.

## Full Disk Access (reviewed 2026-10-12)

What the app does today:

- tccd checks for `kTCCServiceSystemPolicyAllFiles` are recorded like any other service and
  shown as "Full Disk Access" in Permissions, in the Summary's protected data and in the CSV.
  "Files & folders only" includes them (`SystemPolicy` prefix).
- They are real log lines: a public Claude Code issue shows `AUTHREQ_ATTRIBUTION` for
  `SystemPolicyAllFiles`, with `com.apple.sandboxd` as the requester and the agent as the
  responsible process (docs/RESEARCH.md, section 4).

What it does not do:

- **List which apps hold Full Disk Access.** The grants live in the system TCC.db, which
  needs Full Disk Access to read. Apple DTS says even that does not work on macOS 27
  and there is no API. So AppAlibi cannot show the list from System Settings.
- **Log every file read.** tccd is asked once per process (sandboxd caches the answer),
  not once per file. "Which file" stays out of reach without Endpoint Security (Later).

Plan (M2.6):

1. An app counts as **seen holding Full Disk Access** once tccd logs an allowed
   `SystemPolicyAllFiles` result for it. Show that as a badge in Permissions and the AI tab,
   with first and last seen. The label is "seen allowed", not "has", because a grant
   that was never used does not show up.
2. Alert option: "An app is seen with Full Disk Access for the first time". It goes
   with the first-permission alert, but is worth a setting of its own, since Apple
   itself is tightening FDA because of AI agents.
3. The same observed inventory for Accessibility, Screen Recording, Input Monitoring
   and Automation: per app, the last result seen for each service.

## AI clients (planned 2026-10-12)

AI assistants and coding agents can drive the Mac: computer use clicks and types, agents
run shell commands, and some ask for Full Disk Access. The goal is a tab that shows
what each client did, where and when, built mostly from data the app already collects.

### Matching clients

`AIClients.swift` in AlibiKit: a catalog of known clients, matched against every
process tccd names (responsible, accessing and requesting), Control Center bundle IDs
and authd paths. A row belongs to a client if any of those match.

| Client | Match on |
|---|---|
| Claude (desktop) | `com.anthropic.claudefordesktop*` |
| Claude Code | `com.anthropic.claude-code`, paths `~/.local/share/claude/versions/`, `/Claude/claude-code/` |
| ChatGPT and Codex | `com.openai.codex` (new ChatGPT app), `com.openai.chat*` (Classic), `com.openai.sky.CUAService`, a `codex` binary, `@openai/codex` |
| GitHub Copilot | `com.github.CopilotForXcode*`, `@github/copilot`, `copilot` binary |
| Kimi | `com.moonshot.kimichat`, a `kimi` binary |
| Gemini | `@google/gemini-cli`, the desktop app (bundle ID still to find) |
| Cursor | `com.todesktop.230313mzl4w4u92` |
| Perplexity | `ai.perplexity.macv3`, `ai.perplexity.comet`, `perplexityd` |
| Others, later | Windsurf, Raycast, Zed, Warp, Ollama, LM Studio |

- Bundle IDs and paths come from Homebrew casks and vendor issues, not from a
  capture yet. Check each against a real log line before shipping (Open questions).
- Settings gets "Also treat as AI: …" so users can add an app (a file picker, like
  Login Items), because the list will always be behind.
- **The terminal problem.** A CLI agent started in Terminal or iTerm usually inherits
  the terminal as responsible process, so tccd blames iTerm. It works out for:
  - Claude Code's native install: it is signed as `com.anthropic.claude-code` and shows up
    as responsible.
  - Codex and Kimi: their binaries are named in `binary_path`.

  It does not work for Node CLIs (Gemini, Copilot CLI, npm installs). tccd only logs
  `node`, and the script path is not in the line. The fix is to read the live process:
  tccd logs the pid, so while streaming the app can read `KERN_PROCARGS2` (argv) and walk the
  parent chain with `proc_pidinfo` before a short-lived process exits. This works only
  in the live stream, not in the catch-up, and only for the user's own processes. That is
  phase 2.

### Storage

- New table `ai_events`: id, time, client, kind (`sensor`, `tcc`, `admin`, `input`),
  detail (service, sensor or right), app, accessor, binary_path, auth_value,
  preflight, pid, parent (for the terminal case).
- It holds raw rows, not daily aggregates, because "when" needs the exact time. Volume is low:
  a few hundred rows a day, mostly preflight checks. Preflight rows can be folded into
  the hour if that turns out to be too many.
- Written in `EventStore.record` in the same transaction as the aggregates. `TCCAccessEvent`
  already carries all three processes, but the store drops two of them today.
- Sensor sessions are not copied. The tab queries `sessions` by the client's bundle IDs.
- The first launch of this version backfills from the existing aggregates
  (`tcc_access`, `admin_rights`). Those rows only have first and last seen per day, so they are
  marked approximate.

### AI tab (fifth tab, after Admin)

- **Client strip** at the top: one card per client seen in the range, with icon, last
  activity and badges (Screen, Microphone, Control, Full Disk Access, Admin). Clicking a card
  filters the timeline.
- **Timeline table:** Time, Client, What, Where, Result, Via.
  - *What:* in plain words, e.g. "Recorded the screen 4m", "Asked to control the Mac",
    "Opened Documents", "Full Disk Access check", "Got admin rights".
  - *Where:* the resource (folder, service, right) and the app it targeted when known.
  - *Via:* the process chain, e.g. "claude 2.1.216 in iTerm" or "sandboxd for claude".
  - A lock icon marks rows while the screen was locked. Denied results are red.
  - "First time" marks a client's first allowed use of a service.
- Filters: client, range, kind, "Real access only" (hides preflight). Export uses the
  same filters, like the other tabs.
- Summary gets an "AI clients" section: time on screen, mic or camera per client, and
  new access this period.
- Alerts (off by default, switched on as a group in the welcome tour's notification page):
  - an AI client got a service for the first time: Accessibility, Input Monitoring,
    Screen Recording, Full Disk Access or Automation;
  - an AI client used camera, mic, screen or input while the screen was locked;
  - an AI client was granted an admin right.

### Mouse and keyboard ("used the mouse")

- **What macOS gates.** Synthetic mouse and keyboard (`CGEventPost`) is gated by
  `kTCCServicePostEvent`. Reading and pressing other apps' UI (AXUIElement) is gated by
  `kTCCServiceAccessibility`. Watching input (event taps) is gated by `kTCCServiceListenEvent`.
  System Settings shows PostEvent under Accessibility.
- **Our label is wrong.** We label PostEvent "Keyboard Control". It also covers the
  mouse, so rename it "Mouse & Keyboard Control" in AlibiKit's catalog (English and Polish).
- **Nothing per click is logged.** No unified log line is known per synthetic event, and
  macOS shows no indicator for it. Computer use does show in Control Center as `scr`
  (the agent takes screenshots), and the dev Mac already logged `scr` for Claude.

Plan in three steps, cheapest first:

1. **Log only (in M2.6).** For an AI client, an Accessibility or PostEvent check becomes
   "Can control mouse and keyboard". Screen recording sessions from the same
   client are marked "probably computer use" when they come with such a check.
2. **Probe.** Run `log stream` with no predicate while Claude computer use and ChatGPT agent
   drive the Mac. Look for WindowServer, AXRuntime or universalaccessd lines that name
   the posting process. If one exists, it becomes a source in `LogPredicates.swift`.
3. **Input watcher (opt-in, later).** A listen-only `CGEventTap` in AppAlibi. For each
   mouse event it reads `kCGEventSourceUnixProcessID`, the process that posted it. Hardware
   input has no posting app, so any other pid is synthetic input from that app. Bursts
   become "input sessions" with the same start and stop model as sensors.
   - It never stores coordinates or keys. Keyboard events are counted, never read.
   - It needs Input Monitoring for AppAlibi itself. That is a hard ask for a privacy
     app, so the setting has to say exactly why.
   - Live only. Mouse-move events are sampled, not all handled.
   - It cannot see AX actions (`AXPress`), which create no events. Step 1 covers those.
   - To verify: that a tap sees the poster's pid for events from another process.

### Agent transcripts (idea, not planned)

Claude Code (`~/.claude/projects/*/*.jsonl`) and Codex (`~/.codex/sessions/`) keep their
own logs of every command and file edit. Reading only tool names, paths and commands
would answer "what" far better than TCC can. Against it:

- the formats are private and change often;
- the files hold code and secrets;
- it is a different kind of source from the system log.

Revisit after the AI tab ships.

## Speed: slow tab switching (QA 2026-10-12)

Reported: changing tabs (Summary, Sensors, Permissions, Admin) is very slow. Found
by reading the code, since there is no Mac in this session, so nothing here has been timed yet.
In order of likely cost:

1. **Every query runs on the main thread.** Each tab's `.task(id:)` calls `reload()`
   synchronously, so SQLite, scope filtering and building up to 2,000 rows all block the UI.
   `AppModel.refresh()` (menu) does the same on every revision.
2. **Reads wait behind writes.** `EventStore` has one connection behind one `NSLock`. The
   collector holds it for each batch's transaction. That takes long during the catch-up
   (3 days of tccd on first launch) and is frequent while watching (about 17,000 checks a day).
   So a tab switch can wait for a write to finish. WAL mode is on but unused for
   concurrency, because there is only one connection.
3. **Scope filters scan everything.** `tccApps(in:)` runs `SELECT DISTINCT app, binary_path
   FROM tcc_access` over all history on every reload. It then classifies each pair through
   `AppInfo`, which on a cache miss asks LaunchServices for the bundle *and loads the icon*,
   although only the kind is needed. `sessionApps` and `adminRightApps` do the same. The
   result can be hundreds of IDs in an `IN (...)` clause.
4. **Tabs are rebuilt on every switch.** `HistoryView` swaps views in a `switch`, so each
   switch throws away the tab's `@State` (rows, filters), reloads from scratch and
   rebuilds the table and the `.searchable` toolbar. Filters also reset, which is a bug of its own.
5. **Every stored batch reloads.** `revision` bumps on any batch, at most every 400ms, and
   the visible tab and the menu reload even when the batch cannot change them (a tccd
   batch reloads Sensors and Admin).
6. Smaller costs: `TCCAggregate.id` and `AdminRightAggregate.id` build a string on every access
   during table diffing. `PermissionGroup.make` runs in `body`. The Summary has no
   `(preflight, last_seen)` index for its tcc query.

Fix plan (M2.5, before the AI tab, which adds a fifth tab and more rows):

1. Measure first: `os_signpost` around each reload and query, and an
   `alibi-probe --bench` that times each history query against the real database.
2. A read-only second connection for queries (`SQLITE_OPEN_READONLY`, WAL readers do not
   block on the writer), with its own lock. Writes keep the current one.
3. Load off the main actor: queries run in a detached task and the result is assigned
   on the main actor. The old rows stay on screen while loading, and a small spinner
   shows in the toolbar.
4. Keep each tab's state in the model (`@Observable` per tab, owned by `AppModel`), so
   switching back shows the cached rows at once and reloads only if its source changed.
   Filters survive switching.
5. Per-source revisions (`sessionsRevision`, `tccRevision`, `adminRevision`, `locksRevision`),
   bumped from the batch's event kinds. A tab reloads only for its sources, and the
   menu only for sessions.
6. Scope sets cached in `AppModel`, built once in the background and extended only with
   new identifiers from each batch. `AppInfo.kind` stops loading icons, and icons load lazily
   in `AppCell`.
7. Then check whether 2,000 rows per table still costs much. If it does, show 500
   and add a "Show more" button.

Done when switching between any two tabs takes less than 100ms with a 3-month
database on the dev Mac, while the catch-up is running.

Built 2026-10-12: steps 2 to 6. `EventStore` reads through a second, query-only connection.
`TabLoader` (HistoryView.swift) loads off the main actor, and each tab's state lives in `AppModel`.
There are per-source revisions (`sessionsRevision` and so on), and the app kinds are cached and
grow with each batch. Not done yet: the signposts and `--bench` (step 1), and the row limit
check (step 7). The code was written without a compiler. The GitHub Actions build
(`.github/workflows/build.yml`) is the first check, and the result has not been timed on a Mac.

## Open questions

- Can a standard (non-admin) account run `log show` and `log stream`? If not,
  the app needs a privileged helper.
- Do older macOS versions (14, 15) log the same Control Center messages?
- Trademark clearance for AppAlibi against the live ALIBI mark.
- Do the AI client IDs and paths in "AI clients" match real tccd and Control Center lines?
  Capture each client once (Claude desktop computer use, Claude Code in iTerm, ChatGPT agent,
  Codex CLI, Copilot CLI, Kimi) with `log stream` and add the lines as parser tests.
- Does tccd on macOS 27 still name the client in `AUTHREQ_ATTRIBUTION`? One EDR project
  reports it redacted on some versions.
- Does ChatGPT's "Locked Use" authorization plug-in show up in authd or loginwindow lines?
- Does a listen-only event tap see `kCGEventSourceUnixProcessID` for events another process posted?
