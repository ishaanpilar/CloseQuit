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

    /// Every mutation is a read-modify-write against the newest config on disk, unless a
    /// write of ours is already queued. Without this the window can hold a snapshot taken
    /// minutes ago and write the whole thing back, silently undoing an edit made in the
    /// file or by another window. That is exactly how the default exclusions were lost:
    /// a window left open overnight wrote its stale copy back over a corrected file.
    private func mutate(_ change: (inout Config) -> Void) {
        if pendingSave == nil {
            let disk = Config.load()
            if disk != cfg {
                cfg = disk
                mode = (disk.only?.isEmpty == false) ? .only : .exclude
            }
        }
        change(&cfg)
        scheduleSave()
    }

    // Guarded setters. SwiftUI can invoke a Binding's `set` during a re-render with the
    // value it already has; unguarded, that turns a passive redraw into a config write.
    func setDryRun(_ v: Bool) {
        guard (cfg.dryRun ?? false) != v else { return }
        mutate { $0.dryRun = v }
    }

    func setVerbose(_ v: Bool) {
        guard (cfg.verbose ?? false) != v else { return }
        mutate { $0.verbose = v }
    }

    func setPollInterval(_ v: Double) {
        guard cfg.effectivePollInterval != v else { return }
        mutate { $0.pollInterval = v }
    }

    func setZeroReadings(_ v: Int) {
        guard cfg.effectiveZeroReadings != v else { return }
        mutate { $0.zeroReadingsRequired = v }
    }

    func isManaged(_ bundleID: String) -> Bool { cfg.manages(bundleID) }

    /// A row governed by a wildcard must not be toggled directly — doing so would have
    /// to expand the pattern into a concrete list and quietly destroy the rule.
    func lockingPattern(_ bundleID: String) -> String? { cfg.verdict(for: bundleID).pattern }

    func setManaged(_ bundleID: String, _ managed: Bool) {
        guard lockingPattern(bundleID) == nil, isManaged(bundleID) != managed else { return }
        let currentMode = mode
        mutate { c in
            switch currentMode {
            case .only:
                var s = Set(c.only ?? [])
                if managed { s.insert(bundleID) } else { s.remove(bundleID) }
                c.only = s.sorted()
            case .exclude:
                var s = c.effectiveExcluded
                if managed { s.remove(bundleID) } else { s.insert(bundleID) }
                c.setExcluded(s)
            }
        }
    }

    func setMode(_ m: Mode) {
        guard m != mode else { return }
        mode = m
        mutate { c in
            if m == .exclude { c.only = nil } else if c.only == nil { c.only = [] }
        }
        refreshApps()
    }

    var allowlistEmpty: Bool { mode == .only && (cfg.only ?? []).isEmpty }

    func addPattern() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, p.contains("*") else { return }
        let currentMode = mode
        mutate { c in
            switch currentMode {
            case .only:
                var s = Set(c.only ?? []); s.insert(p); c.only = s.sorted()
            case .exclude:
                var s = c.effectiveExcluded; s.insert(p); c.setExcluded(s)
            }
        }
        newPattern = ""
        refreshApps()
    }

    func removePattern(_ p: String) {
        let currentMode = mode
        mutate { c in
            switch currentMode {
            case .only:
                var s = Set(c.only ?? []); s.remove(p); c.only = s.sorted()
            case .exclude:
                var s = c.effectiveExcluded; s.remove(p); c.setExcluded(s)
            }
        }
        refreshApps()
    }

    /// Coalesce bursts from steppers and rapid toggling into one atomic write.
    private func scheduleSave(after delay: TimeInterval = 0.35) {
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

// MARK: - Building blocks

/// Card surfaces, leading row icons, status pills and the tinted callout all come from
/// the design pass. They are deliberately hand-built rather than a `Form`: a grouped
/// Form cannot tint an individual row (the "recommended" treatment on Dry run) or put
/// an icon in the leading edge without fighting it.
private let cardRadius: CGFloat = 8

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: cardRadius))
            .overlay(RoundedRectangle(cornerRadius: cardRadius)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6)))
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text).font(.headline).padding(.bottom, 6)
    }
}

/// A dot plus a word, in a tinted capsule. Says at a glance whether a row is live,
/// idle, or governed by something the user cannot toggle here.
struct StatusPill: View {
    let text: String
    let tint: Color
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Semantic colour, deliberately not `accentColor`. Accent belongs to selection and
/// primary actions; a status surface must mean the same thing for every user. With a red
/// accent an accent-tinted "here is how the timing works" box reads as an error.
private struct InfoCallout: View {
    let icon: String
    let text: String
    var tint: Color = .blue
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: cardRadius))
    }
}

private struct SettingRow<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    /// The one setting that should be on while you learn what the daemon does, so it
    /// gets an accent wash rather than just sitting first in the list.
    var recommended = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(recommended ? Color.blue : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing.padding(.top, 1)
        }
        .padding(12)
        .background(recommended ? Color.blue.opacity(0.10) : Color.clear)
    }
}

/// Stepper first, then the value in its own field — matching the mocks.
private struct SteppedValue<V: Strideable>: View {
    let display: String
    @Binding var value: V
    let range: ClosedRange<V>
    let step: V.Stride

    var body: some View {
        HStack(spacing: 6) {
            Stepper("", value: $value, in: range, step: step).labelsHidden()
            Text(display).monospacedDigit()
                .frame(width: 54)
                .padding(.vertical, 3)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

private struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.title2).foregroundStyle(.secondary)
            Text(title)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .frame(minWidth: 620, minHeight: 640)
        .onReceive(heartbeat) { _ in
            model.refreshDaemon()
            model.reloadIfChangedExternally()
            model.refreshActivity()
        }
    }

    // MARK: Behaviour

    private var behaviour: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "Settings")
                    Card {
                        SettingRow(icon: "shield.lefthalf.filled",
                                   title: "Dry run (recommended)",
                                   subtitle: "Log what would be quit, quit nothing. Leave this on "
                                           + "for a few days, then read the Activity tab.",
                                   recommended: true) {
                            Toggle("", isOn: Binding(
                                get: { model.cfg.dryRun ?? false },
                                set: { model.setDryRun($0) }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                        Divider()
                        SettingRow(icon: "doc.text",
                                   title: "Verbose logging",
                                   subtitle: "Per-tick window counts, not just decisions.") {
                            Toggle("", isOn: Binding(
                                get: { model.cfg.verbose ?? false },
                                set: { model.setVerbose($0) }))
                                .labelsHidden().toggleStyle(.switch)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "Timing")
                    Card {
                        SettingRow(icon: "clock",
                                   title: "Check every",
                                   subtitle: "How often to check for open windows.") {
                            SteppedValue(display: String(format: "%.1f s",
                                                         model.cfg.effectivePollInterval),
                                         value: Binding(
                                            get: { model.cfg.effectivePollInterval },
                                            set: { model.setPollInterval($0) }),
                                         range: 0.2...5.0, step: 0.1)
                        }
                        Divider()
                        SettingRow(icon: "timer",
                                   title: "Zero readings before quitting",
                                   subtitle: "An app must report zero windows this many times.") {
                            SteppedValue(display: "\(model.cfg.effectiveZeroReadings)",
                                         value: Binding(
                                            get: { model.cfg.effectiveZeroReadings },
                                            set: { model.setZeroReadings($0) }),
                                         range: 1...10, step: 1)
                        }
                    }
                }

                // The two steppers only matter as a product, so the product is spelled out.
                InfoCallout(icon: "clock",
                            text: "An app must report zero windows "
                                + "\(model.cfg.effectiveZeroReadings) times in a row — "
                                + String(format: "%.1f s", model.cfg.effectivePollInterval
                                         * Double(model.cfg.effectiveZeroReadings))
                                + " — before it is quit. Raise it if an app quits during a "
                                + "fullscreen transition or a window reload.")
            }
            .padding(16)
        }
    }

    // MARK: Apps

    private var appsTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel(text: "CloseQuit watches")
                        Picker("", selection: Binding(
                            get: { model.mode }, set: { model.setMode($0) })) {
                            ForEach(Mode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                    }
                    Spacer(minLength: 16)
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search apps…", text: $model.search)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(nsColor: .separatorColor)))
                    .frame(width: 230)
                    .padding(.top, 22)
                }

                if model.allowlistEmpty {
                    InfoCallout(icon: "exclamationmark.triangle.fill",
                                text: "No apps turned on yet — until you pick one, CloseQuit "
                                    + "falls back to watching everything except its default "
                                    + "exclusions.",
                                tint: .orange)
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionLabel(text: "Wildcard rules")
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
                                HStack(spacing: 5) {
                                    Text(p).font(.caption).monospaced()
                                    Button { model.removePattern(p) } label: {
                                        Image(systemName: "xmark").font(.caption2)
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                                .overlay(Capsule()
                                    .strokeBorder(Color(nsColor: .separatorColor)))
                            }
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }

                SectionLabel(text: "Apps").padding(.bottom, -6)
            }
            .padding(16)

            if model.filtered.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "No results.",
                           detail: "Try a different filter or clear the search.")
            } else {
                List(model.filtered) { app in appRow(app) }
            }
        }
    }

    private func appRow(_ app: AppEntry) -> some View {
        let locked = model.lockingPattern(app.bundleID)
        return HStack(spacing: 10) {
            icon(for: app.bundleID)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            Toggle("", isOn: Binding(
                get: { model.isManaged(app.bundleID) },
                set: { model.setManaged(app.bundleID, $0) }))
                .labelsHidden().toggleStyle(.switch)
                .disabled(locked != nil)

            Group {
                if let locked {
                    StatusPill(text: "Matched by \(locked)", tint: .blue)
                } else if app.running {
                    StatusPill(text: "Running", tint: .green)
                } else {
                    StatusPill(text: "Not running", tint: .gray)
                }
            }
            .frame(width: 190, alignment: .leading)
        }
        .padding(.vertical, 3)
        .help(locked.map { "Governed by the rule \($0). Remove the rule to set this app on its own." } ?? "")
    }

    @ViewBuilder private func icon(for bundleID: String?) -> some View {
        if let bundleID, let img = Model.icon(for: bundleID) {
            Image(nsImage: img).resizable().frame(width: 22, height: 22)
        } else {
            Image(systemName: "questionmark.app.dashed")
                .foregroundStyle(.secondary).frame(width: 22, height: 22)
        }
    }

    // MARK: Activity

    private var activityTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $model.activityMode) {
                    Text("Summary").tag(0)
                    Text("Log").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)

                if model.activityMode == 1 {
                    Toggle("Decisions only", isOn: $model.quitsOnly).toggleStyle(.checkbox)
                }
                Spacer()
                Text("Log file: ~/Library/Logs/closequit.log")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)

            if model.entries.isEmpty {
                EmptyState(icon: "doc.text",
                           title: "Nothing logged yet.",
                           detail: "Decisions are always logged. Turn on Verbose to see "
                                 + "per-tick counts.")
            } else if model.activityMode == 0 {
                summaryList
            } else {
                logList
            }
        }
    }

    @ViewBuilder private var summaryList: some View {
        let rows = model.summary
        if rows.isEmpty {
            EmptyState(icon: "checkmark.circle",
                       title: "No quit decisions yet.",
                       detail: "The daemon is watching, but nothing has closed its last "
                             + "window so far.")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("\(rows.count) app\(rows.count == 1 ? "" : "s") would have been quit")
                        .fontWeight(.semibold)
                    Text("·").foregroundStyle(.secondary)
                    Text("\(rows.reduce(0) { $0 + $1.decisions }) decisions in the recent log")
                        .foregroundStyle(.secondary)
                }
                .font(.title3)
                .padding(.horizontal, 16).padding(.bottom, 10)

                List(rows) { row in summaryRow(row) }
            }
        }
    }

    private func summaryRow(_ row: AppSummary) -> some View {
        HStack(spacing: 10) {
            icon(for: row.bundleID)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.app)
                Text(row.bundleID ?? "couldn't resolve a bundle id for this name")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text("\(row.decisions)×").monospacedDigit()
                Text("Last \(row.lastSeen)").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 92, alignment: .leading)

            // Reading a dry run and acting on it are the same gesture.
            Group {
                if let id = row.bundleID {
                    if model.lockingPattern(id) != nil {
                        StatusPill(text: "By rule", tint: .blue)
                    } else if model.isManaged(id) {
                        Button("Stop watching") { model.setManaged(id, false) }
                    } else {
                        StatusPill(text: "Not watched", tint: .gray)
                    }
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var logList: some View {
        if model.visibleLog.isEmpty {
            EmptyState(icon: "magnifyingglass", title: "No results.",
                       detail: "Try a different filter or clear the search.")
        } else {
            List(model.visibleLog) { e in
                Text(e.line)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(e.isDecision ? Color.primary : Color.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Footer

    /// Five states, each with its own dot, sentence and primary action. "The process
    /// exists" and "the daemon is working" are different things, and needsRelaunch is a
    /// macOS quirk the user cannot guess their way out of — so it gets the loud button.
    private var banner: (dot: Color, text: String, tint: Color) {
        switch model.health {
        case .notInstalled:
            return (.gray, "Not installed — run ./install.sh", .secondary)
        case .stopped:
            return (.red, "Daemon stopped", .secondary)
        case .waitingForGrant:
            return (.yellow, "Accessibility not granted — CloseQuit is watching nothing", .primary)
        case .needsRelaunch:
            return (.orange,
                    "Accessibility is granted, but the daemon started before you granted it "
                    + "— it needs a relaunch to see it", .primary)
        case .working(let s):
            return (.green,
                    "Running · \(s.dryRun ? "dry run" : "live") · watching \(s.watching) "
                    + "· checked \(s.age)s ago", .secondary)
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch model.health {
        case .waitingForGrant:
            Button("Open Accessibility") { model.openAccessibilitySettings() }
        case .needsRelaunch:
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
            Spacer(minLength: 12)

            primaryAction

            Menu {
                Button("Relaunch daemon") { model.relaunchDaemon() }
                Button("Open Accessibility settings") { model.openAccessibilitySettings() }
                Divider()
                Button("Reveal config file") {
                    NSWorkspace.shared.activateFileViewerSelecting([Config.url])
                }
                Button("Open log file") {
                    if FileManager.default.fileExists(atPath: Model.logURL.path) {
                        NSWorkspace.shared.open(Model.logURL)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [Model.logURL.deletingLastPathComponent()])
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
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
