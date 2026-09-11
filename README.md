# CloseQuit

Makes the red **X** behave like **⌘Q**: when you close an app's *last* window, the
app quits instead of lingering in the Dock with no windows.

A background daemon — no menu bar icon, no settings window, no UI process.

| | |
|---|---|
| Memory | **2.9 MB** at start, ~4.5 MB steady (Activity Monitor "Memory") |
| CPU | 0.0% idle |
| Binary | 127 KB, links no AppKit |
| Code | 232 lines |

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

## Install

```sh
./install.sh
```

Then grant Accessibility: **System Settings → Privacy & Security → Accessibility
→ +** → `~/Applications/CloseQuit.app`. Picked up within a few seconds, no restart.

**It ships in dry-run mode** — it logs what it *would* quit and quits nothing.
Leave it that way for a few days, read the log, then turn it off:

```sh
# ~/.config/closequit/config.json  ->  "dryRun": false
launchctl kickstart -k gui/$UID/com.ishaanpilar.CloseQuit
```

## Config — `~/.config/closequit/config.json`

```json
{
  "alsoExclude": ["com.figma.Desktop"],
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
| `only` | Allowlist. If set, *only* these bundle IDs quit on last close |
| `zeroReadingsRequired` | Raise it if an app quits during a transition |
| `dryRun` | Log decisions, quit nothing |

Excluded by default: Finder, System Settings, Music, TV, Messages, Mail, Activity
Monitor, Spotify, and terminals (Terminal, iTerm, Ghostty, Warp, kitty, Alacritty,
WezTerm) — closing a terminal's last window would kill running jobs.

Menu-bar-only apps (`LSUIElement`) are never touched.

## Commands

```sh
./install.sh      # build + run at login
./uninstall.sh    # remove everything
~/Applications/CloseQuit.app/Contents/MacOS/CloseQuit --list   # what it sees
~/Applications/CloseQuit.app/Contents/MacOS/CloseQuit -v       # run in terminal, verbose
```

`--list` shows apps with windows on the **current Space** only — that is how the
window server reports. The daemon itself is not limited this way; it counts
windows on every Space through Accessibility.

Logs: `~/Library/Logs/closequit.log`

## Notes for future edits

See [PLAN.md](PLAN.md) for the AX quirks table. Short version: don't filter windows
by subrole (Preview's document window is `AXDialog`), don't rely on
`kAXUIElementDestroyedNotification` (never fires for TextEdit), and don't use
`kAXFocusedApplicationAttribute` on the system-wide element (returns -25204).
