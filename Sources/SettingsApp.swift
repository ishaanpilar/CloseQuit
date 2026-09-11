import SwiftUI
import AppKit
import Combine

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
    @Published var activity: [String] = []
    @Published var quitsOnly = false
    @Published var daemonRunning = false
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
        daemonRunning = NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == Model.daemonBundleID }
    }

    /// Tail the log rather than reading it whole — it is append-only and can grow
    /// unbounded, and only the recent end is ever interesting.
    func refreshActivity() {
        guard let h = try? FileHandle(forReadingFrom: Model.logURL) else { activity = []; return }
        defer { try? h.close() }
        let window: UInt64 = 64 * 1024
        let size = (try? h.seekToEnd()) ?? 0
        let truncated = size > window
        try? h.seek(toOffset: truncated ? size - window : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        var lines = text.split(separator: "\n").map(String.init)
        if truncated, !lines.isEmpty { lines.removeFirst() }   // half a line
        activity = Array(lines.suffix(400)).reversed()          // newest first
    }

    var visibleActivity: [String] {
        guard quitsOnly else { return activity }
        return activity.filter { $0.contains("QUIT") || $0.contains("quitting") }
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
                Toggle("Quits only", isOn: $model.quitsOnly).toggleStyle(.switch)
                Spacer()
                Text("~/Library/Logs/closequit.log").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)

            if model.visibleActivity.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing logged yet.").foregroundStyle(.secondary)
                    Text("Decisions are always logged. Turn on Verbose to see per-tick counts.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(model.visibleActivity.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(line.contains("QUIT") || line.contains("quitting")
                                         ? Color.primary : Color.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Circle().fill(model.daemonRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Text(model.daemonRunning
                 ? "Daemon running — changes apply within a second."
                 : "Daemon not running. Run ./install.sh.")
                .font(.callout).foregroundStyle(.secondary)

            if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).lineLimit(1)
            }
            Spacer()

            Button("Accessibility…") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
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
