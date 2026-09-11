import SwiftUI
import AppKit
import Combine
import ApplicationServices

// CloseQuit Settings — a plain window that reads and writes the same config.json
// the daemon watches. There is no IPC and no shared process: you open it, change
// something, close it, and it costs nothing again. The daemon notices the file
// changed within one poll.

// MARK: - Model

struct AppEntry: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let running: Bool
    var id: String { bundleID }
}

/// The daemon logs an app's *name*, not its bundle ID — and that name is the bundle's
/// filename without ".app". So an exact filename match against the standard app
/// directories recovers the ID, including for apps that are no longer running. Doing it
/// here rather than changing the log format keeps the daemon untouched while it is under
/// dry-run observation.
enum AppIndex {
    private static var cache: [String: String]?

    static func bundleID(forName name: String) -> String? {
        if cache == nil { build() }
        return cache?[name]
    }

    static func invalidate() { cache = nil }

    private static func build() {
        var map: [String: String] = [:]
        for a in NSWorkspace.shared.runningApplications {
            guard let id = a.bundleIdentifier, let url = a.bundleURL else { continue }
            map[url.deletingPathExtension().lastPathComponent] = id
        }
        let fm = FileManager.default
        for dir in ["/Applications", "/Applications/Utilities",
                    "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"] {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") {
                let stem = String(n.dropLast(4))
                guard map[stem] == nil,
                      let b = Bundle(url: URL(fileURLWithPath: dir).appendingPathComponent(n)),
                      let id = b.bundleIdentifier else { continue }
                map[stem] = id
            }
        }
        cache = map
    }
}

/// One parsed log line. The log is the only record of what the daemon decided, so the
/// summary is built by reading it back rather than by keeping a second copy of the truth.
struct ActivityEntry: Identifiable {
    enum Kind { case wouldQuit, quit, veto, standDown, lifecycle, chatter }

    let id = UUID()
    let time: String
    let app: String?
    let kind: Kind
    let line: String

    var isDecision: Bool { kind == .wouldQuit || kind == .quit }

    static func parse(_ line: String) -> ActivityEntry? {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
        let time = String(line[line.index(after: line.startIndex)..<close])
        var rest = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)

        // "Safari: last window closed" has an app; "config reloaded — …" does not.
        var app: String?
        if let colon = rest.firstIndex(of: ":") {
            let candidate = String(rest[..<colon])
            if !candidate.contains("—") {
                app = candidate
                rest = String(rest[rest.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        let kind: Kind
        if rest.contains("WOULD QUIT") { kind = .wouldQuit }
        else if rest.contains("last window closed") { kind = .quit }
        else if rest.contains("not quitting") { kind = .veto }
        else if rest.contains("standing down") { kind = .standDown }
        else if app == nil { kind = .lifecycle }
        else { kind = .chatter }

        return ActivityEntry(time: time, app: app, kind: kind, line: line)
    }
}

/// One app's worth of dry-run history — the "what would have happened" row.
struct AppSummary: Identifiable {
    let app: String
    let bundleID: String?
    let decisions: Int
    let lastSeen: String
    var id: String { app }
}

/// What the daemon writes to `~/.config/closequit/status.json` every few seconds.
/// Checking that a process merely exists is not enough: a daemon parked in the
/// Accessibility wait loop is running and doing nothing, and looks identical.
struct DaemonStatus {
    let lastTick: Date
    let axTrusted: Bool
    let state: String
    let dryRun: Bool
    let watching: Int
    let underLaunchd: Bool
    let codeHash: String?

    /// Written every 5s, so anything older means it died or wedged — and a stale
    /// file left behind by a killed process must never read as running.
    var alive: Bool { Date().timeIntervalSince(lastTick) < 12 }
    var age: Int { max(0, Int(Date().timeIntervalSince(lastTick))) }

    static func read() -> DaemonStatus? {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/.config/closequit/status.json")
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tick = o["lastTick"] as? Double else { return nil }
        return DaemonStatus(lastTick: Date(timeIntervalSince1970: tick),
                            axTrusted: o["axTrusted"] as? Bool ?? false,
                            state: o["state"] as? String ?? "granted",
                            dryRun: o["dryRun"] as? Bool ?? false,
                            watching: o["watching"] as? Int ?? 0,
                            underLaunchd: o["underLaunchd"] as? Bool ?? false,
                            codeHash: o["codeHash"] as? String)
    }
}

/// What the footer is actually reporting. Borrowed from SmartClose's
/// PermissionRowStatus: "needs relaunch" is a state of its own, not a flavour of
/// "missing", and it is the one a user cannot guess their way out of.
enum Health {
    case notInstalled       // no LaunchAgent and nothing running
    case stopped            // was running, is not now
    case waitingForGrant    // running, untrusted, prompt is the next step
    case needsRelaunch      // granted since this process started — it cannot see it
    case working(DaemonStatus)
}

enum Mode: String, CaseIterable, Identifiable {
    case exclude, only
    var id: String { rawValue }
    var label: String {
        switch self {
        case .exclude: return "Every app, except the ones I turn off"
        case .only:    return "Only the apps I turn on"
        }
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var cfg = Config.load()
    @Published var mode: Mode
    @Published var apps: [AppEntry] = []
    @Published var search = ""
    @Published var newPattern = ""
    @Published var entries: [ActivityEntry] = []
    @Published var quitsOnly = false
    @Published var activityMode = 0   // 0 = summary, 1 = raw log
    @Published var status: DaemonStatus?
    @Published var launchAgentInstalled = false
    @Published var grantedNow = false
    @Published var error: String?

    private var pendingSave: DispatchWorkItem?
    private var lastWrite: Date?
    private static var iconCache: [String: NSImage?] = [:]

    static let daemonBundleID = "com.ishaanpilar.CloseQuit"
    static let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/closequit.log")

    init() {
        let c = Config.load()
        cfg = c
        mode = (c.only?.isEmpty == false) ? .only : .exclude
        refreshApps()
        refreshDaemon()
        refreshActivity()

        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshApps(); self?.refreshDaemon() }
            }
        }
    }

    // MARK: Discovery

    /// `.regular` is exactly the set the daemon considers: menu-bar agents
    /// (`LSUIElement` / `LSBackgroundOnly`) report `.accessory` or `.prohibited` and the
    /// daemon skips them, so they must not appear here either.
    func refreshApps() {
        var seen: [String: AppEntry] = [:]
        for a in NSWorkspace.shared.runningApplications
        where a.activationPolicy == .regular && a.bundleIdentifier != nil {
            let id = a.bundleIdentifier!
            guard !Config.hardExcluded.contains(id) else { continue }
            seen[id] = AppEntry(bundleID: id, name: a.localizedName ?? id, running: true)
        }
        // Apps named in the config but not running now still need a row, or you could
        // never undo an exclusion for something you have since quit. Patterns are not
        // apps, so they are handled separately.
        for id in cfg.effectiveExcluded.union(cfg.only ?? [])
        where seen[id] == nil && !id.contains("*") && !Config.hardExcluded.contains(id) {
            // Only apps actually installed here. The default exclusion list names half a
            // dozen terminals; showing rows for the ones you do not have is pure noise.
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
            else { continue }
            seen[id] = AppEntry(bundleID: id, name: Model.displayName(for: id), running: false)
        }
        apps = seen.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return url.deletingPathExtension().lastPathComponent
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let hit = iconCache[bundleID] { return hit }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        iconCache[bundleID] = icon
        return icon
    }

    func refreshDaemon() {
        status = DaemonStatus.read()
        launchAgentInstalled = FileManager.default.fileExists(atPath: Model.launchAgentPath)
        // A grant made after the daemon started is invisible to it, but not to us:
        // this process is fresh enough to see the truth.
        grantedNow = AXIsProcessTrusted()
    }

    static let launchAgentPath =
        NSHomeDirectory() + "/Library/LaunchAgents/com.ishaanpilar.CloseQuit.plist"
    static let daemonPath = NSHomeDirectory() + "/Applications/CloseQuit.app"

    var health: Health {
        guard let s = status, s.alive else {
            return launchAgentInstalled ? .stopped : .notInstalled
        }
        if s.axTrusted { return .working(s) }
        return grantedNow ? .needsRelaunch : .waitingForGrant
    }

    /// Under launchd, kickstart -k is the correct restart. Otherwise re-open the
    /// bundle the way SmartClose's AppRelauncher does.
    func relaunchDaemon() {
        let p = Process()
        if launchAgentInstalled {
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["kickstart", "-k", "gui/\(getuid())/com.ishaanpilar.CloseQuit"]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-n", Model.daemonPath]
        }
        do { try p.run() } catch { self.error = error.localizedDescription }
    }

    func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Tail the log rather than reading it whole — it is append-only and can grow
    /// unbounded, and only the recent end is ever interesting.
    func refreshActivity() {
        guard let h = try? FileHandle(forReadingFrom: Model.logURL) else { entries = []; return }
        defer { try? h.close() }
        let window: UInt64 = 256 * 1024
        let size = (try? h.seekToEnd()) ?? 0
        let truncated = size > window
        try? h.seek(toOffset: truncated ? size - window : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        var lines = text.split(separator: "\n").map(String.init)
        if truncated, !lines.isEmpty { lines.removeFirst() }   // half a line
        entries = lines.reversed().compactMap(ActivityEntry.parse)   // newest first
    }

    var visibleLog: [ActivityEntry] {
        Array((quitsOnly ? entries.filter(\.isDecision) : entries).prefix(400))
    }

    /// "What would have happened", which is the question a dry run is actually asking.
    /// Reading it off seven scattered log lines is how the Messages misconfiguration
    /// went unnoticed; as a ranked count it is the first thing you see.
    var summary: [AppSummary] {
        var counts: [String: (n: Int, last: String)] = [:]
        for e in entries where e.isDecision {
            guard let app = e.app else { continue }
            if var hit = counts[app] { hit.n += 1; counts[app] = hit }
            else { counts[app] = (1, e.time) }   // newest-first, so first sighting is latest
        }
        return counts.map {
            AppSummary(app: $0.key, bundleID: AppIndex.bundleID(forName: $0.key),
                       decisions: $0.value.n, lastSeen: $0.value.last)
        }
        .sorted { $0.decisions == $1.decisions ? $0.app < $1.app : $0.decisions > $1.decisions }
    }

    /// Pick up edits made in a text editor, unless we are the ones mid-write.
    func reloadIfChangedExternally() {
        guard pendingSave == nil, let disk = Config.modificationDate() else { return }
        if let mine = lastWrite, disk <= mine.addingTimeInterval(0.5) { return }
        let fresh = Config.load()
        guard fresh != cfg else { return }
        cfg = fresh
        mode = (fresh.only?.isEmpty == false) ? .only : .exclude
        refreshApps()
    }

    // MARK: Editing

    var filtered: [AppEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(q)
            || $0.bundleID.localizedCaseInsensitiveContains(q)
        }
    }

    func isManaged(_ bundleID: String) -> Bool { cfg.manages(bundleID) }

    /// A row governed by a wildcard must not be toggled directly — doing so would have
    /// to expand the pattern into a concrete list and quietly destroy the rule.
    func lockingPattern(_ bundleID: String) -> String? { cfg.verdict(for: bundleID).pattern }

    func setManaged(_ bundleID: String, _ managed: Bool) {
        guard lockingPattern(bundleID) == nil else { return }
        switch mode {
        case .only:
            var s = Set(cfg.only ?? [])
            if managed { s.insert(bundleID) } else { s.remove(bundleID) }
            cfg.only = s.sorted()
        case .exclude:
            var s = cfg.effectiveExcluded
            if managed { s.remove(bundleID) } else { s.insert(bundleID) }
            cfg.setExcluded(s)
        }
        scheduleSave()
    }

    func setMode(_ m: Mode) {
        mode = m
        if m == .exclude { cfg.only = nil } else if cfg.only == nil { cfg.only = [] }
        scheduleSave()
        refreshApps()
    }

    var allowlistEmpty: Bool { mode == .only && (cfg.only ?? []).isEmpty }

    func addPattern() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, p.contains("*") else { return }
        switch mode {
        case .only:
            var s = Set(cfg.only ?? []); s.insert(p); cfg.only = s.sorted()
        case .exclude:
            var s = cfg.effectiveExcluded; s.insert(p); cfg.setExcluded(s)
        }
        newPattern = ""
        scheduleSave(after: 0)
        refreshApps()
    }

    func removePattern(_ p: String) {
        switch mode {
        case .only:
            var s = Set(cfg.only ?? []); s.remove(p); cfg.only = s.sorted()
        case .exclude:
            var s = cfg.effectiveExcluded; s.remove(p); cfg.setExcluded(s)
        }
        scheduleSave(after: 0)
        refreshApps()
    }

    /// Coalesce bursts from steppers and rapid toggling into one atomic write.
    func scheduleSave(after delay: TimeInterval = 0.35) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSave = nil
                do {
                    try self.cfg.save()
                    self.lastWrite = Date()
                    self.error = nil
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

// MARK: - View

struct SettingsView: View {
    @StateObject private var model = Model()
    @State private var tab = 0
    private let heartbeat = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $tab) {
                behaviour.tabItem { Label("Behaviour", systemImage: "gearshape") }.tag(0)
                appsTab.tabItem { Label("Apps", systemImage: "square.grid.2x2") }.tag(1)
                activityTab.tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }.tag(2)
            }
            .padding(.top, 8)
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 640)
        .onReceive(heartbeat) { _ in
            model.refreshDaemon()
            model.reloadIfChangedExternally()
            model.refreshActivity()
        }
    }

    // MARK: Behaviour

    private var behaviour: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.cfg.dryRun ?? false },
                    set: { model.cfg.dryRun = $0; model.scheduleSave() })) {
                    Text("Dry run")
                    Text("Log what would be quit, quit nothing. Leave this on for a few days, "
                         + "then read the Activity tab.")
                }
                Toggle(isOn: Binding(
                    get: { model.cfg.verbose ?? false },
                    set: { model.cfg.verbose = $0; model.scheduleSave() })) {
                    Text("Verbose logging")
                    Text("Per-tick window counts, not just decisions.")
                }
            }

            Section("Timing") {
                LabeledContent("Check every") {
                    HStack {
                        Text(String(format: "%.1f s", model.cfg.effectivePollInterval))
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                        Stepper("", value: Binding(
                            get: { model.cfg.effectivePollInterval },
                            set: { model.cfg.pollInterval = $0; model.scheduleSave() }),
                                in: 0.2...5.0, step: 0.1).labelsHidden()
                    }
                }
                LabeledContent("Zero readings before quitting") {
                    HStack {
                        Text("\(model.cfg.effectiveZeroReadings)")
                            .monospacedDigit().frame(width: 52, alignment: .trailing)
                        Stepper("", value: Binding(
                            get: { model.cfg.effectiveZeroReadings },
                            set: { model.cfg.zeroReadingsRequired = $0; model.scheduleSave() }),
                                in: 1...10).labelsHidden()
                    }
                }
                Text("An app must report zero windows this many times in a row — "
                     + String(format: "%.1f s", model.cfg.effectivePollInterval
                              * Double(model.cfg.effectiveZeroReadings))
                     + " — before it is quit. Raise it if an app quits during a fullscreen "
                     + "transition or a window reload.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Apps

    private var appsTab: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("CloseQuit watches", selection: Binding(
                    get: { model.mode }, set: { model.setMode($0) })) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)

                if model.allowlistEmpty {
                    Label("No apps turned on yet — until you pick one, CloseQuit falls back to "
                          + "watching everything except its default exclusions.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }

                patternEditor
                TextField("Search apps", text: $model.search).textFieldStyle(.roundedBorder)
            }
            .padding(12)

            List(model.filtered) { app in row(app) }
        }
    }

    private var patternEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Wildcard rule, e.g. com.microsoft.*", text: $model.newPattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.addPattern() }
                Button("Add rule") { model.addPattern() }
                    .disabled(!model.newPattern.contains("*"))
            }
            if !model.cfg.patterns.isEmpty {
                HStack(spacing: 6) {
                    ForEach(model.cfg.patterns, id: \.self) { p in
                        HStack(spacing: 4) {
                            Text(p).font(.caption).monospaced()
                            Button {
                                model.removePattern(p)
                            } label: {
                                Image(systemName: "xmark.circle.fill").font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                }
            }
        }
    }

    private func row(_ app: AppEntry) -> some View {
        let locked = model.lockingPattern(app.bundleID)
        return Toggle(isOn: Binding(
            get: { model.isManaged(app.bundleID) },
            set: { model.setManaged(app.bundleID, $0) })) {
            HStack(spacing: 8) {
                if let icon = Model.icon(for: app.bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "app.dashed").frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                    Text(locked.map { "matched by \($0)" } ?? app.bundleID)
                        .font(.caption)
                        .foregroundStyle(locked == nil ? .secondary : Color.accentColor)
                }
                if !app.running {
                    Text("not running").font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(locked != nil)
        .help(locked.map { "Governed by the rule \($0). Remove the rule to set this app on its own." } ?? "")
    }

    // MARK: Activity

    private var activityTab: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.activityMode) {
                    Text("Summary").tag(0)
                    Text("Log").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)

                if model.activityMode == 1 {
                    Toggle("Decisions only", isOn: $model.quitsOnly).toggleStyle(.checkbox)
                }
                Spacer()
                Text("~/Library/Logs/closequit.log").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)

            if model.entries.isEmpty {
                emptyActivity
            } else if model.activityMode == 0 {
                summaryList
            } else {
                logList
            }
        }
    }

    private var emptyActivity: some View {
        VStack(spacing: 6) {
            Text("Nothing logged yet.").foregroundStyle(.secondary)
            Text("Decisions are always logged. Turn on Verbose to see per-tick counts.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var summaryList: some View {
        let rows = model.summary
        if rows.isEmpty {
            VStack(spacing: 6) {
                Text("No quit decisions yet.").foregroundStyle(.secondary)
                Text("The daemon is watching, but nothing has closed its last window so far.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(rows.count) app\(rows.count == 1 ? "" : "s") would have been quit "
                     + "· \(rows.reduce(0) { $0 + $1.decisions }) decisions in the recent log")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 8)

                List(rows) { row in summaryRow(row) }
            }
        }
    }

    private func summaryRow(_ row: AppSummary) -> some View {
        HStack(spacing: 8) {
            if let id = row.bundleID, let icon = Model.icon(for: id) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "questionmark.app.dashed").frame(width: 20, height: 20)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(row.app)
                Text(row.bundleID ?? "couldn't resolve a bundle id for this name")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(row.decisions)×").monospacedDigit()
                Text("last \(row.lastSeen)").font(.caption).foregroundStyle(.secondary)
            }

            // The loop the dry run is for: see it here, act on it here.
            if let id = row.bundleID {
                if model.lockingPattern(id) != nil {
                    Text("by rule").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 118, alignment: .trailing)
                } else if model.isManaged(id) {
                    Button("Stop watching") { model.setManaged(id, false) }
                        .frame(width: 118)
                } else {
                    Text("not watched").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 118, alignment: .trailing)
                }
            } else {
                Text("—").foregroundStyle(.secondary).frame(width: 118, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    private var logList: some View {
        List(model.visibleLog) { e in
            Text(e.line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(e.isDecision ? Color.primary : Color.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: Footer

    private var banner: (dot: Color, text: String, tint: Color) {
        switch model.health {
        case .notInstalled:
            return (.secondary, "Not installed — run ./install.sh", .secondary)
        case .stopped:
            return (.secondary, "Daemon stopped", .secondary)
        case .waitingForGrant:
            return (.orange, "Accessibility not granted — CloseQuit is watching nothing", .orange)
        case .needsRelaunch:
            return (.orange,
                    "Accessibility is granted, but the daemon started before you granted it "
                    + "— it needs a relaunch to see it", .orange)
        case .working(let s):
            return (.green,
                    "Running · \(s.dryRun ? "dry run" : "live") · watching \(s.watching) "
                    + "· checked \(s.age)s ago", .secondary)
        }
    }

    @ViewBuilder private var healthActions: some View {
        switch model.health {
        case .waitingForGrant:
            Button("Open Accessibility") { model.openAccessibilitySettings() }
            Button("Relaunch") { model.relaunchDaemon() }
        case .needsRelaunch:
            // The one action a user cannot guess, so it is the prominent one.
            Button("Relaunch daemon") { model.relaunchDaemon() }
                .buttonStyle(.borderedProminent)
        case .stopped:
            Button("Start") { model.relaunchDaemon() }
        case .notInstalled, .working:
            Button("Accessibility…") { model.openAccessibilitySettings() }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle().fill(banner.dot).frame(width: 8, height: 8)
            Text(banner.text).font(.callout).foregroundStyle(banner.tint)
                .fixedSize(horizontal: false, vertical: true)

            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()

            healthActions
            Button("Config") { NSWorkspace.shared.activateFileViewerSelecting([Config.url]) }
        }
        .padding(12)
    }
}

// MARK: - Entry

@main
struct CloseQuitSettingsApp: App {
    var body: some Scene {
        Window("CloseQuit", id: "settings") { SettingsView() }
            .windowResizability(.contentMinSize)
    }
}
