# AppAlibi

macOS menu bar app that keeps a history of which app used the camera, microphone,
screen recording and TCC-protected resources. Data comes from the unified log
(Control Center `sensor-indicators`, `tccd`, `loginwindow` and `authd`). Ships outside the Mac App Store.

- Research, log formats, competitors, naming and trademark findings: docs/RESEARCH.md
- Architecture, decisions, milestones, open questions: docs/PLAN.md

## Layout

- `AlibiKit/` Swift package with all logic. Apple's private log formats are only
  known by `LogPredicates.swift`, `ControlCenterParser.swift`, `TCC.swift`, `ScreenLock.swift` and `AdminRights.swift`.
- `AlibiKit/Sources/alibi-probe/` CLI that replays recent log history through the pipeline.
- `AppAlibi/` SwiftUI app (thin UI over AlibiKit). Shows in the menu bar or the Dock (user choice).
- `AppAlibi/MacUI/` window handling, menu bar or Dock presentation, onboarding tour and small
  components, ported from ZuckOff's macOS target (`zuckoff` repo, `Mac/ZuckoffMacApp.swift` and
  `Packages/ZuckoffCore/Sources/ZuckoffCore/MacUI/`, on the Mac branches). Keep them in step when one changes.
- `AppAlibi/Notifications/` notification posting, alert and summary preferences, summary scheduler.
- `AppAlibi/AIClients/` the user's own AI clients, client icons, access badges. The catalog of
  known AI clients is `AIClients.swift` in AlibiKit.
- `design/AppIcon.svg` app icon source. `design/render-icon.sh` renders it into the asset catalog.
- `AppAlibi/Localizable.xcstrings` and `AlibiKit/Sources/AlibiKit/Resources/Localizable.xcstrings`
  string catalogs: English source, Polish translations.
- `project.yml` XcodeGen spec. `AppAlibi.xcodeproj` is generated from it; edit the spec, not the project.

## Commands

Run from the repository root.

```bash
xcodegen generate                                   # after editing project.yml or adding app files
swift test --package-path AlibiKit                  # unit tests (fast, no Xcode project needed)
swift run --package-path AlibiKit alibi-probe 6     # check log formats still parse (last 6 hours)
xcodebuild -project AppAlibi.xcodeproj -scheme AppAlibi -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/AppAlibi.app
scripts/sync-strings.sh                             # after a build: new UI strings into the catalogs
```

The app's database is `~/Library/Application Support/AppAlibi/alibi.sqlite`.

## Rules

- Always call `/usr/bin/log` by full path. The zsh builtin `log` shadows it.
- After a macOS update, run `alibi-probe` first. Parser changes need a test with a real captured line.
- No third-party dependencies so far. SQLite goes through the system library. ZuckOff's Mac
  onboarding is a custom view, not OnboardingKit (that package is only linked into ZuckOff for iOS).
- Every user-facing string is localized (English and Polish). SwiftUI literals are picked up
  automatically; strings built as `String` go through `String(localized:)` (in AlibiKit with
  `bundle: .module`). Ternaries of literals pick `String`, so wrap each branch in `Text(...)`.
  Avoid Polish plural forms by writing counts as "Label: N". Translations come from DeepL and are
  reviewed by hand: Apple's Polish terms (Biurko, Pełny dostęp do dysku), informal "ty",
  no gendered past tense for apps or the user.
- The app targets macOS 15 (scene launch and dismiss behaviors). AlibiKit stays at 14.
- Apps versus system services: `AppClassifier` in AlibiKit. Anything inside an Applications folder is an app.
- `.mcp.json` configures Apple's Xcode MCP bridge (`xcrun mcpbridge`). It works only
  while Xcode is running with this project open and external agent access is enabled
  in Xcode's settings. It builds and previews; it cannot create projects.

Status (2026-10-09): M1 done, plus apps-versus-system filter, menu bar or Dock mode, and the welcome tour.
M2 done: app icon, access notifications, daily and weekly summaries, Summary tab, alert for use
while the screen is locked, CSV export, data retention. The welcome tour, Summary tab and Settings
were checked visually before the last three items; their UI (Settings "Keep history" and lock toggle,
Sensors lock icon, filter and Export) was not. Notification delivery was not checked either
(it needs the permission prompt answered). English and Polish localization in; the Polish UI was
not checked visually.
2026-10-10: admin rights (authd grants) source, Admin tab, alert and CSV export, plus names for
more TCC services. Tested with `swift test` and `alibi-probe`. The Admin tab (English, dark) and its Settings toggle
were checked visually. The admin alert was checked end to end with a test binary (delivery seen in
the usernoted log, the banner itself not looked at). The Admin tab and Settings were checked in Polish too.
2026-10-12: M2.5 speed built (store reads on their own connection, tabs load off the main thread
and keep their rows and filters), not timed on a Mac and not checked visually. Planned, not built:
M2.6 AI clients tab, Full Disk Access holders seen in the log, mouse and keyboard control. See docs/PLAN.md.
2026-10-12 later: M2.6 built (AI tab, `ai_access` table, AI and Full Disk Access alerts, access
badges, Summary section, custom AI clients) and Settings split into tabs. Checked visually in
English and Polish on the dev Mac with real data. Not checked: the new notifications'
delivery, the add and remove buttons for custom clients, IDs for Codex, Copilot, Gemini and Cursor.
`.github/workflows/build.yml` builds the app and runs AlibiKitTests with `xcodebuild test` on pull requests
(not `swift test`: on the CI runner the command line copies the string catalog uncompiled, so the Polish test fails).
