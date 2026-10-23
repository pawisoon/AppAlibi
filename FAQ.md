# FAQ

### What does AppAlibi record?

- Which app used the camera, microphone, screen recording or location, and for how long.
- Which apps asked macOS for protected resources (Documents, Desktop, Downloads, Full Disk Access, contacts and so on), and whether they were allowed.
- When the screen was locked, so it can flag the camera, microphone or screen being used while nobody was at the Mac.
- When macOS granted an app administrator rights.
- What AI assistants and coding agents (Claude, ChatGPT, Codex, Copilot, Cursor and others) were allowed to do.

### Where does the data come from?

The macOS unified log. AppAlibi runs `/usr/bin/log` and reads the same events that drive the green and orange privacy dots in the menu bar, plus the permission checks made by `tccd` and admin grants made by `authd`.

### Does anything leave my Mac?

No. History is kept in a SQLite database at `~/Library/Application Support/AppAlibi/alibi.sqlite`. There are no analytics and no network requests.

### Can it tell me which files an app opened?

Only for folders macOS protects (Documents, Desktop, Downloads, removable volumes, Full Disk Access). A full file log would need an Endpoint Security system extension, which AppAlibi doesn't have.

### Why isn't it on the Mac App Store?

The App Store sandbox doesn't allow running `/usr/bin/log`. Releases are signed with a Developer ID and notarized by Apple instead.

### Why is there nothing from before I installed it?

macOS keeps its log for days, not months. On first launch AppAlibi imports what's still there, and from then on it keeps its own copy.

### A macOS update broke something.

The log messages AppAlibi reads aren't a public API, so Apple can change them. Please [open an issue](https://github.com/pawisoon/AppAlibi/issues) with your macOS version.

### What are the system requirements?

macOS 15 or later.
