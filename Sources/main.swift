import Foundation
import ApplicationServices
import CoreServices
import Darwin
import Security

// closequit — quits an app when its last window closes.
// No AppKit, no NSApplication, no UI. A timer and two system calls.

// MARK: - Config

// Resolved values, refreshed from disk whenever the file changes. The config model
// itself lives in Config.swift, shared with the settings app.
var cfg = Config()
var pollInterval = 0.8
var zeroReadingsRequired = 3
var verbose = false
var dryRun = false

// Flags override the file, so `-v` and `--dry-run` stay honoured across reloads.
var forceVerbose = false
var forceDryRun = false

var configSeen: Date?

func applyConfig() {
    pollInterval = cfg.effectivePollInterval
    zeroReadingsRequired = cfg.effectiveZeroReadings
    verbose = (cfg.verbose ?? false) || forceVerbose
    dryRun = (cfg.dryRun ?? false) || forceDryRun
}

/// One stat per tick. Cheap enough to do unconditionally, and it means edits from
/// the settings app (or a text editor) take effect within a poll instead of needing
/// `launchctl kickstart`.
func reloadIfChanged() {
    let stamp = Config.modificationDate()
    guard stamp != configSeen else { return }
    configSeen = stamp
    let previousInterval = pollInterval
    cfg = Config.load()
    applyConfig()
    note("config reloaded — \(settingsSummary())")
    if pollInterval != previousInterval { restartTimer() }
}

func settingsSummary() -> String {
    let scope = cfg.effectiveOnly.map { "only \($0.count) rule(s)" }
        ?? "\(cfg.effectiveExcluded.count) excluded"
    return "poll \(pollInterval)s, \(zeroReadingsRequired) readings, \(scope)\(dryRun ? ", DRY RUN" : "")"
}

// MARK: - Logging
//
// The daemon writes its own log file. It used to write only to stderr and rely on
// the LaunchAgent's StandardErrorPath to put it somewhere — which meant that
// launched any other way (double-clicked from Finder, say) every line went to
// /dev/null and the log simply did not exist.

let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/closequit.log")
let logRotateBytes: UInt64 = 1_000_000
var logHandle: FileHandle?
/// Only echo to stderr when a human is watching. Under launchd this is false, so
/// there is no chance of double-writing into the same file.
let attachedToTerminal = isatty(STDERR_FILENO) == 1

func openLog() {
    let fm = FileManager.default
    try? fm.createDirectory(at: logURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
    logHandle = try? FileHandle(forWritingTo: logURL)
    _ = try? logHandle?.seekToEnd()
}

/// One generation back is enough — this is a debugging aid, not an audit trail.
func rotateIfNeeded() {
    guard let h = logHandle, ((try? h.offset()) ?? 0) > logRotateBytes else { return }
    try? h.close()
    let previous = logURL.appendingPathExtension("1")
    try? FileManager.default.removeItem(at: previous)
    try? FileManager.default.moveItem(at: logURL, to: previous)
    openLog()
}

func stamped(_ s: String) -> Data {
    let t = DateFormatter(); t.dateFormat = "HH:mm:ss"
    return "[\(t.string(from: Date()))] \(s)\n".data(using: .utf8)!
}

func emit(_ s: String) {
    let line = stamped(s)
    if attachedToTerminal { FileHandle.standardError.write(line) }
    rotateIfNeeded()
    try? logHandle?.write(contentsOf: line)
}

/// Chatter — per-tick counts, cancellations. Only with `verbose`.
func log(_ s: String) {
    guard verbose else { return }
    emit(s)
}

/// Decisions — quits, would-be quits, lifecycle. Always written, because a dry run
/// whose log is empty tells you nothing about whether it is safe to switch on.
func note(_ s: String) { emit(s) }

// MARK: - Code identity
//
// SmartClose keeps an AppIdentitySnapshot (bundle id, path, signing identifier) so
// it can tell when the identity a permission was granted to has changed. For an
// ad-hoc signed build the signing identifier never changes — the *cdhash* does, and
// that is what TCC actually binds to. So we report the hash.

func codeSigningHash() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var stat: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &stat) == errSecSuccess, let stat else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(stat, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess,
          let dict = info as? [String: Any],
          let unique = dict[kSecCodeInfoUnique as String] as? Data else { return nil }
    return unique.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Status
//
// So the settings app can distinguish "the process exists" from "the process is
// actually doing its job". A daemon parked in the Accessibility wait loop looks
// identical to a working one from the outside.

let statusURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/closequit/status.json")
/// launchd is pid 1, and is our direct parent when bootstrapped as a LaunchAgent.
/// It decides whether exiting means "restart me" or "goodbye".
let underLaunchd = getppid() == 1
let startedAt = Date()
var lastStatusWrite = Date.distantPast

/// `state` is the field the settings app actually branches on. "waiting" is not the
/// same as "missing": this process cannot observe a grant made after it launched, so
/// it is reporting a condition only a relaunch can clear.
func writeStatus(watching: Int, state: String = "granted", force: Bool = false) {
    let now = Date()
    guard force || now.timeIntervalSince(lastStatusWrite) >= 5 else { return }
    lastStatusWrite = now
    var payload: [String: Any] = [
        "pid": ProcessInfo.processInfo.processIdentifier,
        "startedAt": startedAt.timeIntervalSince1970,
        "lastTick": now.timeIntervalSince1970,
        "axTrusted": AXIsProcessTrusted(),
        "state": state,
        "dryRun": dryRun,
        "watching": watching,
        "underLaunchd": underLaunchd,
    ]
    if let hash = codeSigningHash() { payload["codeHash"] = hash }
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
    try? FileManager.default.createDirectory(
        at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: statusURL, options: .atomic)
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
    return cfg.manages(id.bundleID)
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
    if dryRun { note("\(name): WOULD QUIT (dry run)") }
    else { note("\(name): last window closed — quitting"); quit(pid) }
}

func tick() {
    reloadIfChanged()
    let snap = snapshot()
    for pid in snap.visible { watchlist[pid] = 12 }   // ~10s of grace at 0.8s

    var due = Set<pid_t>()
    for (pid, n) in watchlist {
        due.insert(pid)
        if n <= 1 { watchlist[pid] = nil } else { watchlist[pid] = n - 1 }
    }
    for (pid, st) in states where st.zeroStreak > 0 { due.insert(pid) }
    for pid in due { evaluate(pid, snap) }
    writeStatus(watching: due.filter(eligible).count)
}

// MARK: - Entry

var timer: Timer?

func startTimer() {
    let t = Timer(timeInterval: pollInterval, repeats: true) { _ in tick() }
    RunLoop.main.add(t, forMode: .common)
    timer = t
}

func restartTimer() {
    timer?.invalidate()
    startTimer()
}


func printList() {
    func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }
    let snap = snapshot()
    print(pad("APP", 22) + pad("BUNDLE ID", 38) + pad("AX", 5) + pad("ONSCREEN", 10) + "WATCHED")
    for pid in snap.visible.sorted() {
        guard let id = identity(pid) else { continue }
        let why: String
        if id.isAgent {
            why = "no (menu-bar agent)"
        } else {
            let v = cfg.verdict(for: id.bundleID)
            why = v.managed ? "yes (\(v.reason))" : "no (\(v.reason))"
        }
        print(pad(id.name, 22) + pad(id.bundleID, 38)
              + pad(axWindowCount(pid).map(String.init) ?? "?", 5)
              + pad(snap.bigVisible.contains(pid) ? "yes" : "no", 10) + why)
    }
}

openLog()
forceVerbose = CommandLine.arguments.contains("-v")
forceDryRun = CommandLine.arguments.contains("--dry-run")
configSeen = Config.modificationDate()
cfg = Config.load()
applyConfig()

if CommandLine.arguments.contains("--list") {
    guard AXIsProcessTrusted() else {
        print("Accessibility permission not granted yet — grant it, then rerun."); exit(1)
    }
    printList(); exit(0)
}

// The permission gate.
//
// Measured, the hard way: `AXIsProcessTrusted()` does NOT flip inside a process that
// was already running when the grant was made. The old code looped on it forever and
// claimed in the README that no restart was needed. Both were wrong — the daemon sat
// idle indefinitely while System Settings showed the checkbox ticked.
//
// A fresh process sees the grant immediately, so the fix is to end this one. Under
// launchd, KeepAlive restarts us and the new process is trusted. Launched by hand,
// we exit and the settings window offers a Relaunch button.
if !AXIsProcessTrustedWithOptions(
        [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    note("Accessibility not granted — prompting")
    // Poll briefly anyway: it costs nothing, and if some macOS version does update
    // in-process we skip a needless restart.
    let deadline = Date().addingTimeInterval(45)
    while Date() < deadline, !AXIsProcessTrusted() {
        writeStatus(watching: 0, state: "waiting", force: true)
        Thread.sleep(forTimeInterval: 3)
    }
    if !AXIsProcessTrusted() {
        note(underLaunchd
             ? "still not granted — exiting so launchd restarts us with a fresh check"
             : "still not granted — exiting. Grant it, then relaunch CloseQuit.")
        writeStatus(watching: 0, state: "waiting", force: true)
        exit(1)
    }
    note("Accessibility granted")
}

note("closequit started — \(settingsSummary())")
writeStatus(watching: 0, force: true)
startTimer()
RunLoop.main.run()
