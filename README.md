# AppAlibi

Every app needs an alibi.

AppAlibi is a macOS menu bar app that records a history of which app used your
camera, microphone and screen recording, and which apps asked for protected
resources such as your Documents folder or Full Disk Access.

macOS shows live privacy indicators (the green and orange dots, the Control
Center list), but it keeps no timeline you can look back at. AppAlibi does.

## Build

Requires Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open AppAlibi.xcodeproj
```

Run the `AppAlibi` scheme. The app lives in the menu bar (eye icon) and has no Dock icon.

## How it works

AppAlibi follows the macOS unified log with `/usr/bin/log`. It reads the same
Control Center events that drive the privacy dots, plus tccd permission checks.
Everything stays on your Mac in a local SQLite database. See [docs/](docs/).
