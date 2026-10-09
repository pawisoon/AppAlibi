# Plan

## Goal

A menu bar app that runs at login, watches the macOS unified log, and keeps a
searchable history of:

- **Sensor sessions:** which app used the camera, microphone, screen recording
  or location, from when to when.
- **Permission checks:** which app asked tccd for a protected resource (folders,
  Full Disk Access, contacts, screen capture and so on), and whether it was allowed.

## Data sources (verified 2026-10-09, macOS 27.0.1)

One `log` process watches both sources with a single combined predicate, so
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
  SessionTracker          snapshot diff -> started / ended events
  TCCCorrelator           CTX + ATTRIBUTION + RESULT -> TCCAccessEvent
  EventProcessor          LogEntry stream -> domain events (pure, testable)
  EventStore              SQLite (system libsqlite3, no dependencies)
  AlertPlanner            stored batch -> notifications worth posting (fresh events only)
  ActivityReport          day or week summary: per-app time, hourly or daily bars, permission checks
  ReportSchedule          when the daily or weekly summary notification is due
  LogReader               runs /usr/bin/log, yields batches of LogEntry
  Collector               actor: catch-up with `log show`, then `log stream`
```

### Collector lifecycle

1. Restore the tracker from sessions that are still open in the database.
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
| `meta` | last_processed timestamp |

### UI

- **Menu bar icon:** an eye, filled while camera, mic or screen recording is active.
- **Menu bar panel:** status, "Active now", the last few sessions, Open History, Settings, Quit.
- **History window**, three tabs:
  - *Summary:* Day or Week, laid out like Screen Time: total time with camera,
    mic or screen on, a bar per hour or day, apps by time, then protected data
    per app. A call with camera and mic on counts once (spans are merged).
  - *Sensors:* table of sessions with app icon, sensor, start, duration. Filter by sensor and app.
  - *Permissions:* daily aggregates with app, service, result, count, last seen.
    Apple system processes and preflight checks are hidden by default.
- **Settings:** launch at login, show location, notifications, reveal database, delete history.
- **Notifications** (all off by default, permission asked on first switch-on):
  - camera, mic or screen started by an app: first use per app and sensor, or every session.
    Camera and mic from one app in one batch are one notification. Restarts inside
    the merge gap stay quiet.
  - first real (not preflight) check by an app for a TCC service.
  - daily and weekly summary at a chosen time (default 18:00, weekly on Friday).
    A timer checks every minute and on wake, so a Mac asleep at that time gets it
    on wake if within 6 hours.
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
   Summary tab (done 2026-10-09). Still to do: alert for use while the screen is locked,
   CSV export, data retention setting.
4. **M3 Ship:** Developer ID signing, notarization, Sparkle updates, website on appalibi.com.
5. **Later:** Endpoint Security extension for real file access history.

## Open questions

- Can a standard (non-admin) account run `log show` and `log stream`? If not,
  the app needs a privileged helper.
- Do older macOS versions (14, 15) log the same Control Center messages?
- Trademark clearance for AppAlibi against the live ALIBI mark.
