# CloseQuit

Makes the red **X** behave like **⌘Q**: when you close an app's *last* window, the
app quits instead of lingering in the Dock with no windows.

A background daemon with no UI process — plus a separate settings window you open
only when you need it.

| | |
|---|---|
| Daemon memory | **4.9 MB** steady (`phys_footprint`, what Activity Monitor calls "Memory") |
| Daemon CPU | 0.1% |
| Daemon binary | ~200 KB, links no AppKit and no SwiftUI |
| Settings app | ~590 KB, runs only while its window is open |

Measured with `footprint -p <pid>` on an installed daemon after 8 minutes. `ps` RSS
reads 18 MB for the same process and is not the number to use — most of it is shared
framework pages counted against every process on the system.

## The part that matters: multiple windows

Closing a window is **not** the trigger. The app's window count reaching **zero**
is. Three VS Code windows open, close one, two remain, VS Code keeps running.
Close the last and it quits.

Four guards stop a false quit:

| Guard | Stops |
|---|---|
| Count must be `0`, not "a window closed" | Quitting VS Code when you close one of several |
| 3 consecutive zero readings (~1.5s) | Windows destroyed and instantly rebuilt: fullscreen transitions, window reloads, tearing out a tab |
| App must have reported ≥1 window via AX at least once | After Effects, which reports **0** AX windows with its main window open on screen |
| Window-server cross-check | Anything AX is wrong about — a real on-screen app-sized window vetoes the quit |

A failed AX read is *unknown*, never *zero* — it stands down.

Minimized windows and windows on other Spaces still count, so they keep the app
alive. Quitting uses the same Apple Event the Dock sends, so unsaved-changes
prompts still appear and still let you cancel.

Because the trigger is the count and not the click, closing an auxiliary window —
a Find & Replace panel, an inspector, a dialog — can never quit the app on its own.
The real windows are still there, so the count never reaches zero.

## Install

```sh
./install.sh
```

Then grant Accessibility: **System Settings → Privacy & Security → Accessibility
→ +** → `~/Applications/CloseQuit.app`.

**A running process cannot see a grant made after it started.** `AXIsProcessTrusted()`
does not flip; only a fresh process sees it. So the daemon exits when it is untrusted
and lets launchd restart it — it heals itself within about 15 seconds of you granting.
The settings window says which of those states you are in, and offers a Relaunch
button when that is the thing that is needed.

Recommended first run, so nothing can be quit while you find out what it does:

```sh
./setup-signing.sh   # once, so rebuilds stop revoking the permission
./install.sh
```

**It ships in dry-run mode** — it logs what it *would* quit and quits nothing.
Leave it that way for a few days and read the Activity tab, then turn it off.

## Settings

```sh
open "$HOME/Applications/CloseQuit Settings.app"
```

A separate app on purpose. It links SwiftUI and AppKit, which the daemon must never
do — but it only exists while its window is open, so it costs nothing the rest of
the time. The two processes never talk to each other; they share `config.json`.

- **Behaviour** — dry run, verbose logging, poll interval, zero readings.
- **Apps** — a switch per running app, plus wildcard rules like `com.microsoft.*`.
  Choose between watching everything except what you turn off, or only what you
  turn on.
- **Activity** — two views of the same log. **Summary** ranks apps by how often they
  would have been quit, with a *Stop watching* button on each row, so reading a dry
  run and acting on it are the same gesture. **Log** is the raw tail, newest first,
  with a decisions-only filter.

**Changes apply within about a second.** The daemon stats the config file each tick
and reloads when it changes, so there is nothing to restart.

Editing `config.json` in a text editor still works and is picked up the same way.

## Accessibility, and why it keeps breaking

Two separate traps, both of which produce the same symptom: the daemon runs, uses
no CPU, and quits nothing.

**1. Every rebuild revokes the grant.** macOS binds an Accessibility grant to the
app's *designated requirement*. Under an ad-hoc signature that requirement is the
binary hash, so any code change invalidates it:

```
designated => identifier "com.ishaanpilar.CloseQuit" and cdhash H"..."
```

Run `./setup-signing.sh` once. It creates a self-signed code-signing certificate
named `CloseQuit Local`, and the requirement becomes:

```
designated => identifier "com.ishaanpilar.CloseQuit" and certificate leaf = H"..."
```

No binary hash, so the grant survives rebuilds. `build.sh` picks the identity up
automatically; `CODESIGN_IDENTITY` overrides it if you have a real one. With
neither, it falls back to ad-hoc and warns.

**2. A running process never sees a new grant.** `AXIsProcessTrusted()` returns
false for the life of a process that started before the permission was given —
measured, not assumed. The old code looped on it forever and this README used to
claim no restart was needed. Both were wrong.

The daemon now exits when untrusted; launchd's `KeepAlive` restarts it, and the new
process is trusted. `ThrottleInterval` is 15s, so it heals within about that. Run by
hand instead of under launchd, it exits and the settings window offers **Relaunch**.

After a signature change you usually have to **remove** the old Accessibility entry
with `−` and add it again — ticking the existing checkbox is not enough. If the list
gets into a confusing state, clear it outright:

```sh
tccutil reset Accessibility com.ishaanpilar.CloseQuit
```

## Config — `~/.config/closequit/config.json`

```json
{
  "alsoExclude": ["com.figma.Desktop", "com.microsoft.*"],
  "pollInterval": 0.8,
  "zeroReadingsRequired": 3,
  "dryRun": false,
  "verbose": false
}
```

| Key | Meaning |
|---|---|
| `exclude` | Replaces the default never-quit list |
| `alsoExclude` | Adds to it — usually what you want |
| `only` | Allowlist. If set and non-empty, *only* these quit on last close |
| `pollInterval` | Seconds between checks, floored at 0.2 |
| `zeroReadingsRequired` | Raise it if an app quits during a transition |
| `dryRun` | Log decisions, quit nothing |
| `verbose` | Add per-tick window counts to the log |

Any entry in `exclude`, `alsoExclude`, or `only` may use `*` as a wildcard —
`com.microsoft.*` covers the whole suite. The longest matching rule wins, so a
specific bundle ID beats a broad pattern. Apps governed by a wildcard show as
locked in the settings window, because toggling one would have to expand the
pattern into a concrete list and silently destroy the rule.

Excluded by default: Finder, System Settings, Music, TV, Messages, Mail, Activity
Monitor, Spotify, and terminals (Terminal, iTerm, Ghostty, Warp, kitty, Alacritty,
WezTerm) — closing a terminal's last window would kill running jobs. Replacing
`exclude` drops all of these, which is the point of the key.

Menu-bar-only apps (`LSUIElement`) are never touched.

**Hard exclusions**, which no config can opt into: Dock, loginwindow,
SystemUIServer, WindowServer, Control Center, Notification Center, and CloseQuit's
own two bundle IDs. Quitting any of those is either destructive or meaningless.

## Commands

```sh
./setup-signing.sh  # once — stable signing identity, so rebuilds keep the grant
./install.sh      # build both apps + run the daemon at login
./build.sh settings   # rebuild only the settings app, leaving a running daemon alone
./build.sh daemon     # rebuild only the daemon
./uninstall.sh    # remove both; leaves your config in place
~/Applications/CloseQuit.app/Contents/MacOS/CloseQuit --list   # what it sees, and why
~/Applications/CloseQuit.app/Contents/MacOS/CloseQuit -v       # run in terminal, verbose
```

`--list` shows apps with windows on the **current Space** only — that is how the
window server reports. The daemon itself is not limited this way; it counts
windows on every Space through Accessibility. Each row says whether the app is
watched and why (`watched`, `excluded`, `excluded by com.microsoft.*`,
`not in allowlist`, `never quit`, `menu-bar agent`).

Logs: `~/Library/Logs/closequit.log`, written by the daemon itself — it used to
write only to stderr and rely on the LaunchAgent to redirect it, which meant that
launched any other way (double-clicked from Finder, say) the log did not exist at
all. Decisions are always written; `verbose` adds the per-tick chatter. Rotates at
1 MB, keeping one generation as `closequit.log.1`. When run from a terminal it also
echoes to stderr. `closequit.crash.log` catches anything launchd sees.

`~/.config/closequit/status.json` is written every 5s: pid, `startedAt`, `lastTick`,
`axTrusted`, `state`, `dryRun`, `watching`, `underLaunchd`, and `codeHash`. That is
what the settings footer reads — checking that a process exists is not enough,
because an untrusted daemon looks identical to a working one from the outside.

`codeHash` is the signature's cdhash. If it changes between two runs, a rebuild
happened, and under ad-hoc signing that alone explains a lost permission.

## Layout

```
Sources/Config.swift       # the config model, shared by both binaries
Sources/main.swift         # the daemon
Sources/SettingsApp.swift  # the settings window
```

## Notes for future edits

See [PLAN.md](PLAN.md) for the AX quirks table. Short version: don't filter windows
by subrole (Preview's document window is `AXDialog`), don't rely on
`kAXUIElementDestroyedNotification` (never fires for TextEdit), and don't use
`kAXFocusedApplicationAttribute` on the system-wide element (returns -25204).
