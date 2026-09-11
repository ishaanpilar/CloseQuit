# CloseQuit — plan

**Scope decision: this is a background daemon, not an app.** No menu bar icon, no
settings window, no Sparkle, no UI process. One binary, one config file, one
launchd job. The previous six-tier app plan is dropped.

---

## Why: measured, not assumed

| Build | `ps` RSS | Real footprint | CPU idle |
|---|---|---|---|
| AppKit + `NSApplication` (v1) | 31.8 MB | **7.6 MB** | 0.0% |
| CoreFoundation only (v2) | 9.6 MB | **2.9 MB** | 0.0% |

`ps` RSS is misleading — most of it is shared framework pages counted against
every process on the system. Real footprint (what Activity Monitor shows) is the
number that matters. Dropping AppKit cut it **2.6x**, to 2.9 MB.

For reference: Finder's footprint is ~100 MB, a menu bar app is typically 30–60 MB.

### What dropping AppKit cost

Two things had to be replaced, both verified working:

- **Quitting an app.** `NSRunningApplication.terminate()` → a raw `kAEQuitApplication`
  Apple Event via `AESendMessage`. Same graceful quit the Dock sends, so
  unsaved-changes prompts still appear. **Verified: no TCC "wants to control" prompt**
  (returns 0), which was the main risk.
- **Knowing which apps to watch.** `NSWorkspace.runningApplications` → pids drawn
  from the window-server snapshot we already take each tick.
  `kAXFocusedApplicationAttribute` on the system-wide element was tried first and
  **fails with -25204 (cannotComplete)** — do not reach for it again.

Identity (bundle ID, `LSUIElement`) now comes from `proc_pidpath` + `CFBundle`, cached per pid.

---

## The four guards — unchanged, and the whole point

These survived the rewrite intact. They are the product.

1. **Zero, not delta.** A window closing is never the trigger. The count reaching zero is.
2. **Sustained.** 3 consecutive zero readings (~1.5s), so a window destroyed and rebuilt — fullscreen transition, window reload, tab torn out — never reads as a close.
3. **Trustworthy source.** The app must have reported ≥1 AX window at least once.
4. **Window-server veto.** No quit if a real on-screen ≥400x300 window exists.

Plus: **unknown is never zero** — a failed AX read stands down.

### Quirks that must stay encoded

| Finding | Consequence |
|---|---|
| **After Effects reports 0 AX windows** with its main window on screen | Guard 3 exists solely for this. Without it, closing any AE dialog quits AE |
| **Preview's document window has subrole `AXDialog`** | Cannot filter windows by subrole — count them all |
| **`kAXUIElementDestroyedNotification` never fires for TextEdit** | Per-window destroy notifications are not dependable. Must poll |
| **`kAXFocusedApplicationAttribute` returns -25204** | Discover apps from `CGWindowList`, not from focus |
| Every app owns 1710x34 menubar strips; VS Code/Notes own an offscreen 500x500 helper | Window-server filters need layer 0 + on-screen + size floor, or they match junk |
| `kCGWindowName` needs Screen Recording permission | Never use window titles in logic |
| AX count includes minimized + other-Space windows | Correct and desirable — they keep the app alive |

---

## Shape

```
closequit/
├── Sources/main.swift        # ~250 lines, the whole thing
├── build.sh                  # swiftc -> ~/Applications/closequit
├── install.sh                # build + LaunchAgent + permission instructions
├── uninstall.sh
└── README.md
```

Config is `~/.config/closequit/config.json`. Editing a JSON file *is* the settings
UI. That is the correct amount of interface for something that should be invisible.

---

## What's in scope

Everything here is a few lines and needs no UI.

- [x] Close last window → quit
- [x] Per-app exclusions / `only` allowlist
- [x] `dryRun` — logs what it would quit, quits nothing
- [x] `--list` — what the daemon sees, for debugging
- [x] Terminal/Finder/media default exclusions
- [ ] **Idle quit** — windowless app for N minutes → quit. ~15 lines, catches what you ⌘W'd and forgot. The one genuinely worthwhile addition
- [ ] **`closequit pause 1h`** — touch a file the daemon checks. Kill switch without a UI
- [ ] Log to `~/Library/Logs/closequit.log` with rotation

## What's cut, and why

| Cut | Reason |
|---|---|
| Menu bar app, settings window | This is the memory the daemon is trying to save. A config file does the job |
| Green-button maximize, hold-⌘Q, ⌘W remap | Needs a `CGEventTap` — a second permission, a second class of bug, and a fundamentally different program. If wanted, it is a *separate* tiny daemon, not a feature here |
| Rules engine (battery, Focus, displays) | Conditions belong in a product with a UI to express them |
| Undo notifications, regret detection, stats | All require UI |
| Audio / transfer detection | No reliable public per-process API. Exclusions handle it honestly |
| Session snapshots | Different product |
| Notarization, DMG, Sparkle | Not shipping it to strangers |

---

## Remaining work

1. Port the validated v2 engine into `Sources/main.swift`, replacing the AppKit version.
2. Rerun the live matrix: VS Code, After Effects, Preview, Finder, Safari, Photoshop.
3. Add idle quit + pause.
4. Run with `dryRun: true` for a week. Read the log. Ship only when it's boring.

**Total: a few hours, not a few weeks.**

---

## Open question

Does the daemon watch all apps by default, or only an allowlist? Default-on is
what you asked for; allowlist is safer. `dryRun` for the first week makes
default-on survivable, and the log tells you which apps to exclude before it ever
quits anything.
