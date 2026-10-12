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

## 4. AI clients (2026-10-12)

Web research only. Nothing here has been captured on the dev Mac yet. Several vendor
pages could not be fetched from the research machine, so items marked (S) come from
search result summaries and need checking.

### Identifiers and what they ask for

| Client | Bundle ID and paths | Permissions (feature) | Acts on the Mac by |
|---|---|---|---|
| Claude desktop | `com.anthropic.claudefordesktop`, helper `.helper`; `Contents/Helpers/disclaimer` | Accessibility and Screen Recording (computer use) | Computer use with per-app tiers, Claude in Chrome (native host in `Contents/Helpers/chrome-native-host`), MCP servers |
| Claude Code | `com.anthropic.claude-code` (team Q6L2SF6YDW); `~/.local/bin/claude` -> `~/.local/share/claude/versions/<ver>`; inside the desktop app `~/Library/Application Support/Claude/claude-code/<ver>/claude.app` | Accessibility and Screen Recording for its computer-use MCP; otherwise whatever the terminal has | Shell, file edits, MCP, Chrome, computer use (shows a "Claude is using your computer" notification) |
| ChatGPT (2026 app) | `com.openai.codex`, computer use service `com.openai.sky.CUAService`, `/Library/Application Support/CodexComputerUseAuthorizationPlugin`, `~/.codex` | Accessibility and Screen Recording (computer use). "Locked Use" installs an authorization plug-in (S) | Agent, Codex, computer use with per-app approval |
| ChatGPT Classic | `com.openai.chat`, launch agent `com.openai.chat-helper` | Accessibility (Work with Apps), Microphone and Screen & System Audio Recording (Record) | Reads other apps' text, edits code in Xcode and VS Code |
| Codex CLI | `codex` binary (cask or npm `@openai/codex`), `~/.codex/sessions/` | The terminal's | Shell commands inside `sandbox-exec` |
| Copilot for Xcode | `com.github.CopilotForXcode` | Accessibility, background item, Source Editor extension | Agent mode, MCP (S) |
| Copilot CLI | npm `@github/copilot` (Node), `brew install copilot-cli` | The terminal's | Shell, file edits |
| Kimi | `com.moonshot.kimichat` (inside `Kimi Installer.app/Contents/Helpers/Kimi.app`), `~/.kimi-work`; CLI `kimi` via `uv tool install kimi-cli` (S) | Not found | Browser actions and local files (S), CLI shell mode |
| Cursor | `com.todesktop.230313mzl4w4u92`, `~/.cursor` | Its terminal children use Cursor's grants | Agent, MCP |
| Perplexity | `ai.perplexity.macv3`, daemon `perplexityd`; Comet `ai.perplexity.comet` | "Personal Computer" asks for Accessibility, Screen & System Audio Recording and Full Disk Access (S) | AppleScript and Accessibility |
| Gemini | CLI npm `@google/gemini-cli`; desktop app bundle ID not found | Desktop: screen sharing, Accessibility (S) | CLI: shell in `sandbox-exec` |
| Local models | Ollama `com.electron.ollama` + `com.ollama.ollama`, LM Studio `ai.elementlabs.lmstudio` | | Serve models to other agents |

Not verified: Windsurf (`com.exafunction.windsurf`?), Dia (`company.thebrowser.dia`?),
Microsoft Copilot (Mac App Store).

### How tccd blames a CLI agent

- A child process inherits its parent's responsible process, so a CLI started in iTerm
  is normally attributed to iTerm. `responsibility_spawnattrs_setdisclaim` (private,
  used by LLDB, Chromium and Electron) lets a child become responsible for itself.
- A real Claude Code line (from a public issue) names it directly:
  `responsible={identifier=com.anthropic.claude-code, responsible_path=~/.local/share/claude/versions/2.1.216, ...}, accessing={identifier=com.anthropic.claude-code, ...}, requesting={identifier=com.apple.sandboxd, binary_path=/usr/libexec/sandboxd}`.
  It was logged for SystemPolicyAllFiles, Documents, Desktop, Downloads, MediaLibrary and FileProviderDomain.
- Node CLIs log only `node` as the binary. The script path (`@google/gemini-cli`,
  `@github/copilot`) is not in the line, so the pid has to be resolved while the process lives.
- One EDR project reports tccd redacting the client in `AUTHREQ_CTX` and `AUTHREQ_RESULT`
  on some version. Check with `alibi-probe`.

### Full Disk Access

- `kTCCServiceSystemPolicyAllFiles` checks appear in tccd lines, requested by sandboxd.
- Not every file read is logged: the Claude Code issue shows one burst of checks per
  process, not one per file (caching not documented).
- There is no API to list apps that hold Full Disk Access. The system TCC.db needs FDA,
  and Apple DTS says reading it fails on macOS 27 even with FDA. The answer is to probe
  protected paths, which tells an app only about itself.
- Apple said on 2026-10-02 it will make Full Disk Access harder to grant because of AI
  agents, with no version or date given (S).

### Mouse and keyboard control

| TCC service | Gates | Shown in System Settings as |
|---|---|---|
| `kTCCServicePostEvent` | `CGEventPost`, synthetic mouse and keyboard | Accessibility |
| `kTCCServiceAccessibility` | AXUIElement reading and actions, global `NSEvent` monitors | Accessibility |
| `kTCCServiceListenEvent` | `CGEventTap` | Input Monitoring |

- WindowServer checks PostEvent and ListenEvent for a running app (Apple DTS).
- No unified log line per synthetic event or event tap is documented, and macOS shows
  no indicator for synthetic control. Computer use takes screenshots, so it shows as
  `scr` in Control Center.
- The process holding Secure Input is in `ioreg` (`kCGSSessionSecureInputPID`, undocumented).

### Incidents

- Claude Code ran `rm -rf ... ~/` and wiped a home directory (December 2025, Docker blog).
- The Nx "s1ngularity" npm malware ran `claude --dangerously-skip-permissions`,
  `gemini --yolo` and `q --trust-all-tools` to search for wallets, SSH keys and `.env`
  files (August 2025, Snyk and Semgrep).
- Codex deleting most of a home directory (July 2026) and a ChatGPT Mac app code
  injection flaw found by Objective-See (fixed September 2026) were found in summaries only (S).

### Competitors for AI monitoring

Bitdefender AI Guardian (beta, policy for Claude Code), Safety (getsafety.com, via MDM),
sentinel-mac (FSEvents and lsof), AgentPeek and similar (agent status only), osquery
(Endpoint Security process events). Objective-See has LuLu and BlockBlock but nothing for
AI. None of them keeps a history from the TCC and Control Center log, which is what AppAlibi does.

### Sources

- Homebrew casks: https://github.com/Homebrew/homebrew-cask/blob/main/Casks/c/claude.rb,
  https://raw.githubusercontent.com/Homebrew/homebrew-cask/main/Casks/c/claude-code.rb,
  https://github.com/Homebrew/homebrew-cask/blob/main/Casks/c/chatgpt.rb,
  https://raw.githubusercontent.com/Homebrew/homebrew-cask/main/Casks/c/chatgpt-classic.rb,
  https://github.com/Homebrew/homebrew-cask/blob/main/Casks/c/codex.rb,
  https://raw.githubusercontent.com/Homebrew/homebrew-cask/main/Casks/k/kimi.rb,
  https://github.com/Homebrew/homebrew-cask/blob/main/Casks/c/cursor.rb,
  https://github.com/Homebrew/homebrew-cask/blob/main/Casks/p/perplexity.rb,
  https://github.com/Homebrew/homebrew-cask/blob/main/Casks/c/comet.rb
- Claude: https://code.claude.com/docs/en/desktop, https://code.claude.com/docs/en/computer-use,
  https://code.claude.com/docs/en/sessions, https://github.com/anthropics/claude-code/issues/61233,
  https://github.com/anthropics/claude-code/issues/66216, https://github.com/anthropics/claude-code/issues/82543
- OpenAI: https://developers.openai.com/codex/app/computer-use,
  https://help.openai.com/en/articles/10119604-work-with-apps-on-macos, https://heise.de/-11306153
- GitHub: https://github.com/github/CopilotForXcode,
  https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli
- Kimi: https://www.kimi.com/it/help/kimi-work/overview
- Gemini CLI sandbox: https://www.geminicli.com/docs/cli/sandbox
- Responsible process: https://www.qt.io/blog/the-curious-case-of-the-responsible-process
- tccd redaction report: https://github.com/synthaea-lab/edr-new/issues/354
- TCC.db on macOS 27: https://developer.apple.com/forums/thread/841091
- Input services: https://developer.apple.com/forums/thread/820594, https://developer.apple.com/forums/thread/844416
- Secure Input: https://fnordig.de/til/macOS/secure-input.html
- Incidents: https://www.docker.com/blog/coding-agent-horror-stories-the-rm-rf-incident/,
  https://semgrep.dev/blog/2025/security-alert-nx-compromised-to-steal-wallets-and-credentials,
  https://incidentdatabase.ai/cite/1671/
- Apple on FDA: https://www.computing.co.uk/news/2026/ai/apple-tightens-permission-controls-to-lower-agentic-risk
- Competitors: https://www.scworld.com/brief/bitdefender-releases-ai-guardian-to-secure-autonomous-software-agents,
  https://pypi.org/project/sentinel-mac, https://objective-see.org/tools.html
