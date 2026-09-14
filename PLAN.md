# CloseQuit — plan

**Scope decision: this is a background daemon, not an app.** No menu bar icon, no
Sparkle, no resident UI process. One daemon, one config file, one launchd job.
The previous six-tier app plan is dropped.

**Amended: there is now a settings window, and it costs nothing.** The original
cut conflated "a UI" with "a resident process". Only the second one costs memory.
`CloseQuit Settings.app` is a separate binary that links SwiftUI and AppKit, opens
when you launch it, and is gone when you close it. The daemon never links it,
never launches it, and does not know it exists — they share `config.json` and
nothing else. A resident menu bar app is still cut, for the original reason.

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
CloseQuit/
├── Sources/Config.swift       # the config model — the only thing both binaries share
├── Sources/main.swift         # the daemon: ~280 lines, no AppKit, no SwiftUI
├── Sources/SettingsApp.swift  # the settings window: SwiftUI, on demand only
├── build.sh                   # swiftc -> ~/Applications/{CloseQuit,CloseQuit Settings}.app
├── install.sh                 # build + LaunchAgent + permission instructions
├── uninstall.sh
└── README.md
```

Config is `~/.config/closequit/config.json`, and it stays the source of truth:
the settings window is a view onto that file, not a database in front of it.
Hand-editing it still works, and the daemon picks either up within a tick. The
model round-trips `exclude` / `alsoExclude` / `only` faithfully rather than
flattening them, so opening the settings window never silently rewrites a
hand-written config.

---

## What's in scope

Everything here is a few lines and needs no UI.

- [x] Close last window → quit
- [x] Per-app exclusions / `only` allowlist
- [x] `dryRun` — logs what it would quit, quits nothing
- [x] `--list` — what the daemon sees, for debugging
- [x] Terminal/Finder/media default exclusions
- [x] **Config hot-reload** — the daemon stats the file each tick, so edits apply in <1s. This was the prerequisite for settings of any kind; without it every change needed `launchctl kickstart`
- [x] **Settings window** — on-demand, three tabs: Behaviour, Apps, Activity
- [x] **Decisions always logged** — `WOULD QUIT` used to be gated behind `verbose`, so the documented "run dry for a week and read the log" workflow produced an empty file
- [x] **Wildcard rules** — `com.microsoft.*`, longest match wins
- [x] **Hard exclusions** — Dock, loginwindow, SystemUIServer, WindowServer, Control Center, Notification Center, and CloseQuit itself. No config can opt in
- [ ] **Idle quit** — windowless app for N minutes → quit. ~15 lines, catches what you ⌘W'd and forgot. The one genuinely worthwhile addition
- [ ] **`closequit pause 1h`** — touch a file the daemon checks. Kill switch without a UI
- [x] **The daemon writes its own log** — it wrote only to stderr and depended on the LaunchAgent's `StandardErrorPath`. Launched any other way, every line went to `/dev/null` and the log did not exist, so the Activity tab was permanently empty
- [x] **Log rotation** — 1 MB, one generation kept
- [x] **Status file** — `status.json` every 5s, so the settings window can tell *running* from *working*
- [x] **Stable code-signing identity in `build.sh`** — see below
- [ ] **`identities` cache eviction** — entries are only dropped for pids that reach `evaluate()`, so pids that fall off the watchlist before dying leak. Small, but this process is meant to run for months

## What's cut, and why

| Cut | Reason |
|---|---|
| Resident menu bar app | This is the memory the daemon is trying to save. An on-demand settings window gets the same job done for 0 MB when closed |
| Green-button maximize, hold-⌘Q, ⌘W remap | Needs a `CGEventTap` — a second permission, a second class of bug, and a fundamentally different program. If wanted, it is a *separate* tiny daemon, not a feature here |
| Rules engine (battery, Focus, displays) | Conditions belong in a product with a UI to express them |
| Undo notifications, regret detection, stats | All require UI |
| Audio / transfer detection | No reliable public per-process API. Exclusions handle it honestly |
| Session snapshots | Different product |
| Notarization, DMG, Sparkle | Not shipping it to strangers |

---

## Remaining work

1. Rerun the live matrix: VS Code, After Effects, Preview, Finder, Safari, Photoshop.
2. ~~Re-measure the daemon's real footprint.~~ Done: **4.9 MB** `phys_footprint` after
   8 minutes installed, 0.1% CPU. Against 2.9 MB at start / 4.5 MB steady from the
   original v2 measurement — so the steady figure held and the table above stands.
3. Add idle quit + pause.
4. Log rotation, and evict `identities` for pids that leave the watchlist.
5. Run with `dryRun: true` for a week. Read the Activity tab. Ship only when it's boring.

---

## Two Accessibility traps, both measured

**A running process never observes a new grant.** `AXIsProcessTrusted()` stays false
for the life of a process that started before the permission was given. Verified
directly: granted the permission, watched `axTrusted` stay `false` in a daemon with
193s of uptime, killed it, and the next process reported `true` and `watching: 3`
immediately.

The old gate looped on `AXIsProcessTrusted()` forever and the README promised "no
restart needed". Both wrong, and the failure is silent. The daemon now exits when
untrusted and relies on launchd `KeepAlive` + `ThrottleInterval 15` to restart it
with a fresh check; the settings window offers Relaunch when there is no launchd.

This is what SmartClose's `PermissionRowStatus.recoveryNeeded` ("Needs relaunch")
and `AppRelauncher` exist for. They reached the same conclusion.

## The ad-hoc signing trap

macOS binds an Accessibility grant to the app's designated requirement. Under an
ad-hoc signature that requirement is the binary hash, so **every code change
revokes the permission**. Verified: two builds from identical sources produce the
same CDHash, and any source change produces a different one.

The failure is silent and looks exactly like a logic bug — the daemon runs, uses no
CPU, and quits nothing. It cost real debugging time. Three defences now exist:

1. `build.sh` prefers a stable identity — `CODESIGN_IDENTITY`, or a self-signed
   certificate named `CloseQuit Local` — and warns loudly when it falls back to ad-hoc.
2. The daemon logs the wait and reports `axTrusted` in `status.json`.
3. The settings footer turns orange and names the cause.

`./setup-signing.sh` creates the certificate non-interactively. Note that importing
is not enough — an untrusted certificate reports `CSSMERR_TP_NOT_TRUSTED` and
codesign will not use it; `security add-trusted-cert` is the step that matters.

Do not "fix" a mysteriously idle daemon by rewriting the engine. Check `axTrusted`
and `codeHash` in `status.json` first.

### A measurement trap that cost time

`CloseQuit --list` run from a terminal reported working AX data while the daemon was
untrusted, which looked like proof the permission was fine. It was not: TCC attributes
a request to the **responsible process**, and for a binary exec'd from a shell that is
the terminal. The test was reading the terminal's grant. Judge the daemon only by
`axTrusted` in `status.json`, never by running the binary by hand.

## Working during a dry-run observation window

The two binaries being independent turns out to be a scheduling property as well as a
memory one. While the daemon is under observation:

- **Do not touch the daemon.** Changing the engine mid-evaluation invalidates the
  evaluation, and a restart wipes the in-memory guard state — every app has to
  re-earn `trustworthy`.
- **The settings app is free to change.** `./build.sh settings` rebuilds only that
  bundle, so a running daemon is never replaced or restarted. Verified: same pid,
  uninterrupted uptime, across repeated settings builds.
- **Config edits are free too.** They hot-reload, so fixing exclusions costs the
  observation nothing.

This is why the Activity summary was built before idle quit and pause, which are
daemon changes and belong in one batch after the window closes.

## The settings window can clobber the config

Found the hard way, twice: the window held a `Config` loaded at launch and wrote the
whole struct back on any change. A window left open overnight therefore wrote its
stale copy over a file that had been corrected in the meantime, silently restoring
the exclusion list that had just been removed. SwiftUI makes this worse than it
sounds — a `Binding`'s `set` can fire during a re-render with the value it already
has, so a passive redraw becomes a full config write.

Two fixes, both required:

1. **Every mutation is a read-modify-write.** `Model.mutate` re-reads the file first
   (unless one of our own writes is already queued), applies just that edit, then
   saves. An external edit can no longer be lost to a stale snapshot.
2. **Guarded setters.** `setDryRun`, `setVerbose`, `setPollInterval`,
   `setZeroReadings`, `setMode` and `setManaged` all return early when the value has
   not actually changed, so a redraw cannot write anything at all.

No view writes `cfg` directly any more; `scheduleSave` is private.

## Colour: semantic, not accent

The design mocks used blue for the "recommended" wash, the timing callout and the
"matched by rule" pill. Implemented literally as `accentColor` those follow the user's
system accent — and on a machine with a red accent an informational box reads as an
error. Status surfaces now use fixed semantic colours (blue for information, orange
for warning, green/red/yellow/orange/grey for the footer states). `accentColor` is
left to selection and primary actions, where the system already uses it.

## Notes on SmartClose

[mahirozdin/SmartClose](https://github.com/mahirozdin/SmartClose) solves the same
problem with a different architecture, and it is worth being explicit about which
differences are improvements and which are trades.

**It intercepts the click.** A `CGEventTap` catches the press on the red button and
decides *before* the window closes, so it knows which window was clicked and can
act instantly. CloseQuit polls window counts and reacts *after* the count hits
zero. The trade is real in both directions:

| | SmartClose | CloseQuit |
|---|---|---|
| Permissions | Accessibility **and** Input Monitoring | Accessibility only |
| Latency | Immediate | Up to `pollInterval × zeroReadings` |
| Knows which window closed | Yes | No |
| Catches ⌘W, menu Close, scripted closes | Only via a separate opt-in ⌘W path | Yes, all of them, for free |

Catching every route to zero with one permission and no event tap is the reason to
stay with polling. PLAN already cut event taps for this reason; nothing here
changes that.

**Taken from it:**

- **Wildcard rules.** `com.microsoft.*`, longest pattern wins. Cheap and genuinely useful.
- **Hard exclusions.** A floor no config can opt into. All of them are agent processes
  the daemon skips anyway, but it also covers someone putting Dock in an `only` list.
- **Reasons attached to decisions.** `Config.verdict(for:)` returns why, not just
  whether, which is what makes `--list` and the log answer "why didn't it quit X?".
- **A diagnostics view.** The Activity tab is the single best idea in that repo: it
  is what makes a dry run readable without opening Console.

**Deliberately not taken:**

- **Subrole filtering.** SmartClose puts `AXDialog` in its ignored-subroles set. For
  CloseQuit that is a false-quit bug: Preview's *document* window has subrole
  `AXDialog` (see the quirks table above). SmartClose gets away with it because its
  failure mode is passing the click through, which is harmless; ours is quitting an
  app with a live window. **Do not filter windows by subrole.**
- **Its auxiliary-window handling.** CloseQuit is immune by construction — closing a
  Find & Replace panel leaves the real windows open, so the count never reaches zero
  and nothing happens. No special case needed.
- **Per-app close *behaviour* policies.** They only make sense when you are
  intercepting the click and can choose what the click does. We aren't; on/off is
  the whole space.
- **Onboarding, localization, notarized DMG, SMAppService login item.** All correct
  for something shipped to strangers. Out of scope here.

---

## Open question

Does the daemon watch all apps by default, or only an allowlist? Default-on is
what you asked for; allowlist is safer. `dryRun` for the first week makes
default-on survivable, and the log tells you which apps to exclude before it ever
quits anything.
