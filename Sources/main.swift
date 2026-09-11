import Foundation
import ApplicationServices
import CoreServices
import Darwin

// closequit — quits an app when its last window closes.
// No AppKit, no NSApplication, no UI. A timer and two system calls.

// MARK: - Config

var excluded: Set<String> = [
    "com.apple.finder", "com.apple.systempreferences", "com.apple.Music",
    "com.apple.TV", "com.apple.MobileSMS", "com.apple.mail",
    "com.apple.ActivityMonitor", "com.spotify.client",
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
    "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
]
var only: Set<String>?
var pollInterval = 0.8
var zeroReadingsRequired = 3
var verbose = false
var dryRun = false

func loadConfig() {
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/.config/closequit/config.json")
    guard let data = try? Data(contentsOf: url),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
    if let v = o["exclude"] as? [String] { excluded = Set(v) }
    if let v = o["alsoExclude"] as? [String] { excluded.formUnion(v) }
    if let v = o["only"] as? [String], !v.isEmpty { only = Set(v) }
    if let v = o["pollInterval"] as? Double { pollInterval = max(0.2, v) }
    if let v = o["zeroReadingsRequired"] as? Int { zeroReadingsRequired = max(1, v) }
    if let v = o["verbose"] as? Bool { verbose = v }
    if let v = o["dryRun"] as? Bool { dryRun = v }
}

func log(_ s: String) {
    guard verbose else { return }
    let t = DateFormatter(); t.dateFormat = "HH:mm:ss"
    FileHandle.standardError.write("[\(t.string(from: Date()))] \(s)\n".data(using: .utf8)!)
}

// MARK: - Process identity

struct Identity { let bundleID: String; let isAgent: Bool; let name: String }
var identities: [pid_t: Identity] = [:]

func identity(_ pid: pid_t) -> Identity? {
    if let cached = identities[pid] { return cached }
    var buf = [CChar](repeating: 0, count: 4096)
    guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
    let path = String(cString: buf)
    guard let r = path.range(of: ".app/Contents/MacOS/") else { return nil }
    let bundleURL = URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app")
    guard let b = CFBundleCreate(nil, bundleURL as CFURL) else { return nil }
    let info = CFBundleGetInfoDictionary(b) as? [String: Any] ?? [:]
    func flag(_ k: String) -> Bool {
        if let v = info[k] as? Bool { return v }
        if let v = info[k] as? String { return v == "1" || v.lowercased() == "true" }
        return false
    }
    let id = Identity(bundleID: (CFBundleGetIdentifier(b) as String?) ?? "",
                      isAgent: flag("LSUIElement") || flag("LSBackgroundOnly"),
                      name: bundleURL.deletingPathExtension().lastPathComponent)
    identities[pid] = id
    return id
}

func eligible(_ pid: pid_t) -> Bool {
    guard let id = identity(pid), !id.isAgent, !id.bundleID.isEmpty else { return false }
    if let only { return only.contains(id.bundleID) }
    return !excluded.contains(id.bundleID)
}

// MARK: - Window counting

/// Windows the app exposes to Accessibility: includes minimized ones and ones on
/// other Spaces. nil means "couldn't read" — never treat that as zero.
func axWindowCount(_ pid: pid_t) -> Int? {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 1.0)
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &v) == .success
    else { return nil }
    return (v as? [AXUIElement])?.count ?? 0
}

/// One window-server snapshot per tick, used for two things:
///   `visible`    — which pids currently show a real window (app discovery;
///                  `kAXFocusedApplicationAttribute` returns -25204 on the
///                  system-wide element, so we cannot ask who is frontmost)
///   `bigVisible` — the veto set, for apps Accessibility is blind to (After
///                  Effects reports 0 AX windows with its main window on screen)
struct Snapshot {
    var visible = Set<pid_t>()
    var bigVisible = Set<pid_t>()
}

func snapshot() -> Snapshot {
    var s = Snapshot()
    let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
    else { return s }
    for w in info {
        guard let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowIsOnscreen as String] as? Bool) == true,
              let b = w[kCGWindowBounds as String] as? [String: Any] else { continue }
        let width = b["Width"] as? Double ?? 0, height = b["Height"] as? Double ?? 0
        // Skip the 1710x34 menubar strips every app owns.
        if width >= 200 && height >= 150 { s.visible.insert(pid) }
        if width >= 400 && height >= 300 { s.bigVisible.insert(pid) }
    }
    return s
}

/// Graceful quit — same Apple Event the Dock sends, so unsaved-changes prompts
/// still appear. No Automation permission needed.
func quit(_ pid: pid_t) {
    var p = pid, target = AEDesc(), event = AEDesc(), reply = AEDesc()
    AECreateDesc(typeKernelProcessID, &p, MemoryLayout<pid_t>.size, &target)
    AECreateAppleEvent(kCoreEventClass, kAEQuitApplication, &target,
                       AEReturnID(kAutoGenerateReturnID), AETransactionID(kAnyTransactionID), &event)
    AESendMessage(&event, &reply, AESendMode(kAENoReply), 0)
    AEDisposeDesc(&target); AEDisposeDesc(&event); AEDisposeDesc(&reply)
}

// MARK: - Engine

struct State { var lastCount: Int?; var zeroStreak = 0; var trustworthy = false; var quitRequested = false }
var states: [pid_t: State] = [:]
/// pid -> ticks left to keep watching after it stops being frontmost, so closing
/// the last window and immediately switching apps is still caught.
var watchlist: [pid_t: Int] = [:]

func evaluate(_ pid: pid_t, _ snap: Snapshot) {
    guard kill(pid, 0) == 0 || errno != ESRCH else {
        states[pid] = nil; watchlist[pid] = nil; identities[pid] = nil; return
    }
    guard eligible(pid) else { return }
    var s = states[pid] ?? State()
    let name = identity(pid)?.name ?? "pid \(pid)"

    guard let count = axWindowCount(pid) else {
        log("\(name): count unavailable — standing down"); s.zeroStreak = 0; states[pid] = s; return
    }

    if count > 0 {
        if s.zeroStreak > 0 { log("\(name): \(count) window(s) — cancelling") }
        s.trustworthy = true; s.quitRequested = false; s.zeroStreak = 0; s.lastCount = count
        states[pid] = s; return
    }

    let previous = s.lastCount
    s.lastCount = 0
    defer { states[pid] = s }

    // Guards, in order: must have proven AX works; must be a transition from
    // having windows; must be sustained; window server must agree.
    guard s.trustworthy, !s.quitRequested else { return }
    if s.zeroStreak == 0 && (previous == nil || previous == 0) { return }

    s.zeroStreak += 1
    if s.zeroStreak < zeroReadingsRequired {
        log("\(name): zero windows (\(s.zeroStreak)/\(zeroReadingsRequired))"); return
    }
    if snap.bigVisible.contains(pid) {
        log("\(name): AX says zero but a window is on screen — not quitting")
        s.zeroStreak = 0; return
    }

    s.zeroStreak = 0; s.quitRequested = true
    if dryRun { log("\(name): WOULD QUIT (dry run)") }
    else { log("\(name): last window closed — quitting"); quit(pid) }
}

func tick() {
    let snap = snapshot()
    for pid in snap.visible { watchlist[pid] = 12 }   // ~10s of grace at 0.8s

    var due = Set<pid_t>()
    for (pid, n) in watchlist {
        due.insert(pid)
        if n <= 1 { watchlist[pid] = nil } else { watchlist[pid] = n - 1 }
    }
    for (pid, st) in states where st.zeroStreak > 0 { due.insert(pid) }
    for pid in due { evaluate(pid, snap) }
}

// MARK: - Entry

func printList() {
    func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
    let snap = snapshot()
    print(pad("APP", 22) + pad("BUNDLE ID", 38) + pad("AX", 5) + pad("ONSCREEN", 10) + "WATCHED")
    for pid in snap.visible.sorted() {
        guard let id = identity(pid) else { continue }
        let why: String
        if id.isAgent { why = "no (menu-bar agent)" }
        else if let only { why = only.contains(id.bundleID) ? "yes" : "no (not in only)" }
        else { why = excluded.contains(id.bundleID) ? "no (excluded)" : "yes" }
        print(pad(id.name, 22) + pad(id.bundleID, 38)
              + pad(axWindowCount(pid).map(String.init) ?? "?", 5)
              + pad(snap.bigVisible.contains(pid) ? "yes" : "no", 10) + why)
    }
}

loadConfig()
if CommandLine.arguments.contains("-v") { verbose = true }
if CommandLine.arguments.contains("--dry-run") { dryRun = true }

if CommandLine.arguments.contains("--list") {
    guard AXIsProcessTrusted() else {
        print("Accessibility permission not granted yet — grant it, then rerun."); exit(1)
    }
    printList(); exit(0)
}

// Prompt once, then wait in-process. Picks the grant up within a few seconds, so
// there is nothing to restart after granting.
if !AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    FileHandle.standardError.write("closequit: waiting for Accessibility permission\n".data(using: .utf8)!)
    while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 3) }
}

log("closequit started (poll \(pollInterval)s, \(zeroReadingsRequired) readings\(dryRun ? ", DRY RUN" : ""))")
let timer = Timer(timeInterval: pollInterval, repeats: true) { _ in tick() }
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()
