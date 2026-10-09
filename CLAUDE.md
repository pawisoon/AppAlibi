# AppAlibi

macOS menu bar app that keeps a history of which app used the camera, microphone,
screen recording and TCC-protected resources. Data comes from the unified log
(Control Center `sensor-indicators` and `tccd`). Ships outside the Mac App Store.

- Research, log formats, competitors, naming and trademark findings: docs/RESEARCH.md
- Architecture, decisions, milestones, open questions: docs/PLAN.md

## Layout

- `AlibiKit/` Swift package with all logic. Apple's private log formats are only
  known by `LogPredicates.swift`, `ControlCenterParser.swift`, `TCC.swift` and `ScreenLock.swift`.
- `AlibiKit/Sources/alibi-probe/` CLI that replays recent log history through the pipeline.
- `AppAlibi/` SwiftUI app (thin UI over AlibiKit). Shows in the menu bar or the Dock (user choice).
- `AppAlibi/MacUI/` window handling, menu bar or Dock presentation, onboarding tour and small
  components, ported from ZuckOff's macOS target (`zuckoff` repo, `Mac/ZuckoffMacApp.swift` and
  `Packages/ZuckoffCore/Sources/ZuckoffCore/MacUI/`, on the Mac branches). Keep them in step when one changes.
- `AppAlibi/Notifications/` notification posting, alert and summary preferences, summary scheduler.
- `design/AppIcon.svg` app icon source. `design/render-icon.sh` renders it into the asset catalog.
- `project.yml` XcodeGen spec. `AppAlibi.xcodeproj` is generated from it; edit the spec, not the project.

## Commands

Run from the repository root.

```bash
xcodegen generate                                   # after editing project.yml or adding app files
swift test --package-path AlibiKit                  # unit tests (fast, no Xcode project needed)
swift run --package-path AlibiKit alibi-probe 6     # check log formats still parse (last 6 hours)
xcodebuild -project AppAlibi.xcodeproj -scheme AppAlibi -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/AppAlibi.app
```

The app's database is `~/Library/Application Support/AppAlibi/alibi.sqlite`.

## Rules

- Always call `/usr/bin/log` by full path. The zsh builtin `log` shadows it.
- After a macOS update, run `alibi-probe` first. Parser changes need a test with a real captured line.
- No third-party dependencies so far. SQLite goes through the system library. ZuckOff's Mac
  onboarding is a custom view, not OnboardingKit (that package is only linked into ZuckOff for iOS).
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
(it needs the permission prompt answered).
