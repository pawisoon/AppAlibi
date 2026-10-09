# Research

Research done 2026-10-07 to 2026-10-09 on macOS 27.0.1 (build 26A434).

## 1. Technical feasibility: yes

Everything needed is already in the macOS unified log. On the test Mac it was
readable from a normal user shell (admin account) without root.

Not yet verified: whether a standard (non-admin) account can read these entries.

### Gotcha

In zsh, the builtin `log` shadows `/usr/bin/log` and fails with
`log:1: too many arguments`. Always call `/usr/bin/log` by full path.

### Source A: Control Center privacy indicators (camera, mic, screen, location)

These are the same events that drive the green, orange and purple dots.

```bash
/usr/bin/log show --last 24h --style compact \
  --predicate 'subsystem == "com.apple.controlcenter" AND category == "sensor-indicators"'
```

Useful messages (real samples from the test Mac):

```
SystemStatus attributed attribution to com.apple.FaceTime, displayName: <private>, bundlePath: <private>, executablePath: <private>, isSystemExecutable: true
Sorted active attributions from SystemStatus update: [[cam] FaceTime (com.apple.FaceTime), [loc] System Services ()]
Recent activity attributions changed to []
```

- Bundle IDs are logged in clear text. Display name and paths are redacted (`<private>`).
- Each "Sorted active attributions" line is a full snapshot of what is active.
  Diffing consecutive snapshots gives start and stop events per app and sensor.
- Tags seen: `[cam]` camera, `[mic]` microphone, `[scr]` screen recording, `[loc]` location.

Seven-day tally on the test Mac:

| Tag | Count | Apps |
|---|---|---|
| loc | 1030 | System Services, Weather |
| cam | 592 | FaceTime |
| scr | 40 | Claude, Screenshot |
| mic | 2 | QuickTime Player |

#### Better line: "Active activity attributions" (found 2026-10-09)

The app parses this line instead of "Sorted active attributions". It is a JSON
array of `tag:bundleID`, emitted on every change:

```
Active activity attributions changed to ["cam:com.microsoft.teams2", "loc:System Services", "mic:com.microsoft.teams2"]
Active activity attributions changed to []
```

- Screen recording appears as `scr:com.apple.systemuiserver` for screenshots.
- During calls Control Center drops and re-adds a sensor for a second or two.
  The store merges a restart within 5 seconds into the previous session.
- Location (`loc:System Services`) changes every few minutes, so the UI hides it by default.

### Source B: tccd (permission checks, including protected folders)

```bash
/usr/bin/log show --last 24h --style compact \
  --predicate 'process == "tccd" AND (eventMessage CONTAINS "AUTHREQ_ATTRIBUTION" OR eventMessage CONTAINS "service=\"kTCCService")'
```

- `AUTHREQ_ATTRIBUTION` lines carry `responsible`, `accessing` and `requesting`
  processes, each with bundle identifier, pid and binary path.
- Request lines carry `service="kTCCService..."` and a `target_token` with the pid.
- Services seen in seven days: SystemPolicyAppBundles, Microphone, AudioCapture,
  Reminders, Calendar, AddressBook, SystemPolicyDocumentsFolder, SystemPolicyDesktopFolder.

#### tccd details (found 2026-10-09)

- One check is three lines sharing `msgID`: `AUTHREQ_CTX` (service, preflight),
  `AUTHREQ_ATTRIBUTION` (processes) and `AUTHREQ_RESULT` (`authValue`: 0 denied,
  1 unknown, 2 allowed, 3 limited). There are two tccd processes (system and
  per-user), so the join key is `(tccd pid, msgID)`.
- The attribution names any of `responsible`, `accessing` and `requesting`.
  About 2.5% of lines name only `requesting`: a process checking its own access.
- About 90% of checks are `preflight=yes` (asking, not accessing).
- Volume: about 17,000 checks a day on the dev Mac, stored as daily aggregates.

### Framing

- `log stream --style ndjson` prints a plain-text "Filtering the log data…" line first.
- `log show --style ndjson` ends with `{"count":N,"finished":1}`.
- `log show --start` accepts `yyyy-MM-dd HH:mm:ss+zzzz`.
- Replaying 24 hours of both sources takes about 40 seconds, almost all inside `log`.
- Child `log` processes outlive the app unless terminated on quit.

### Limits

- **Disk access** is only visible for TCC-protected locations: Documents, Desktop,
  Downloads, removable volumes, Full Disk Access. A full "which app opened which
  file" log needs Endpoint Security: a system extension plus an Apple-granted
  entitlement. That is phase 2 at the earliest.
- **Log format is private.** Apple can change message text between macOS releases.
  Keep all predicates and parsers in one place and test on each beta.
- **Distribution:** the app sandbox blocks spawning `/usr/bin/log`, so the Mac App
  Store is out. Ship with Developer ID signing and notarization.
- Unified log retention is limited (days, not months), so the app must run
  continuously and store events in its own database.

## 2. Competitors

Searched the Mac App Store via the iTunes Search API, the web and GitHub.
GitHub's API returned empty results from this machine, so GitHub was covered
through web search only.

| App | Covers | History | Price | Notes |
|---|---|---|---|---|
| Micro Snitch (Objective Development) | camera, mic | log file | $3.99, Mac App Store | last update 1.6.1, 2023-09-12, no ratings |
| OverSight (Objective-See) | camera, mic | none built in | free, GPL-3.0 | v2.4.0, macOS 12+, ~681 GitHub stars, not on the Mac App Store |
| oversight-logger (script) | camera, mic | text log | free | shell script hooked into OverSight |
| Micro Sniff (Dwarves Foundation) | mic | none | free | indicator only |

**Gap:** no app combines camera, mic, screen recording and TCC permission events
in one searchable history. Nothing found logs screen recording by app at all.
9to5Mac (2026-04-24) still recommends OverSight for "what used my camera while
I was away", which confirms the gap.

## 3. Naming

Candidates considered: RedHanded, Whodunnit, Hall Monitor, Alibi, Kapuś, Nosy,
MyAlibi, AppAlibi. **Chosen: AppAlibi** (folder name, 2026-10-09).

### AppAlibi

| Check | Result |
|---|---|
| Mac and iOS App Store | no app with this name |
| Google | no product with this name |
| appalibi.com, .app, .io, .dev, getappalibi.com | no nameservers on 2026-10-09, probably free |
| USPTO exact APPALIBI | not checked directly (search API refused), nothing found via web |

### Trademark risk: live ALIBI mark

- US reg. 4549324, serial 86110549, word mark ALIBI.
- Owner: Observint Technologies, Inc. (brand Alibi Security), Austin, Texas.
- Status: LIVE, renewed 2024-02-26.
- Class 9: cameras, video recorders, security equipment, surveillance software.
- Observint ships "Alibi Vigilant CMS" on the Mac App Store (Utilities).

AppAlibi overlaps the dominant word in a nearby field (security software touching
cameras). Risk is lower than plain "Alibi" but not zero. Get a short legal
clearance opinion before spending on the brand or filing a trademark.

### Other names checked

| Name | Finding |
|---|---|
| Alibi | live ALIBI mark (above), ~17 iOS apps, all good domains taken. Rejected. |
| MyAlibi | MYALIBI US reg. 5638600 (The Stephen Group) cancelled 2025-07-11. myalibi.com, .app, .dev probably free. Same ALIBI overlap. Reads as protecting the user, not catching apps. |
| RedHanded | US REDHANDED reg. 4822332 (Red 5 Studios) cancelled 2022-04-08. Canada TMA917451 same owner, LIVE until 2030-10-19, anti-cheat software. No Mac app. redhanded.com, .app, .io taken. Big true-crime podcast dominates search. Best fit for the product's job. |

### Sources

- https://apps.apple.com/us/app/micro-snitch/id972028355?mt=12
- https://objective-see.org/products/oversight.html
- https://github.com/objective-see/OverSight
- https://kwm.me/posts/oversight-logger/
- https://9to5mac.com/2026/04/24/security-bite-this-app-tells-you-if-your-macs-webcam-or-mic-was-triggered-while-you-were-away/
- https://tsdr.uspto.gov/statusview/sn86110549 (ALIBI, live)
- https://tsdr.uspto.gov/statusview/sn87357143 (MYALIBI, cancelled)
- https://tsdr.uspto.gov/statusview/sn85447834 (REDHANDED, cancelled)
- https://ised-isde.canada.ca/cipo/trademark-search/pdf/1572182?lang=eng (REDHANDED Canada, live)
