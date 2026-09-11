import Foundation

/// The on-disk config at `~/.config/closequit/config.json`, modelled faithfully so
/// the settings app can round-trip a hand-edited file without quietly rewriting
/// choices the user made. Every field is optional because `nil` means "key absent",
/// which is not the same as an empty array — `"only": []` means no allowlist, while
/// no `only` key at all means the same thing but must not be written back.
struct Config: Codable, Equatable {
    var exclude: [String]?          // replaces the defaults outright
    var alsoExclude: [String]?      // adds to the defaults — usually what you want
    var only: [String]?             // allowlist; when non-empty it wins over both
    var pollInterval: Double?
    var zeroReadingsRequired: Int?
    var verbose: Bool?
    var dryRun: Bool?

    /// Never quit these unless the user explicitly replaces the list. Terminals are
    /// here because closing the last window would kill whatever is running in it.
    static let defaultExcluded: Set<String> = [
        "com.apple.finder", "com.apple.systempreferences", "com.apple.Music",
        "com.apple.TV", "com.apple.MobileSMS", "com.apple.mail",
        "com.apple.ActivityMonitor", "com.spotify.client",
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty", "com.github.wez.wezterm",
    ]

    /// Quitting these is either destructive or meaningless, so no config can opt in —
    /// unlike `defaultExcluded`, which is only a starting point the user may replace.
    /// (Idea taken from SmartClose's hard-exclusion list.) They are all background or
    /// agent processes the daemon skips anyway; this is the belt to that braces, and it
    /// also covers the case where someone puts one in an `only` allowlist.
    static let hardExcluded: Set<String> = [
        "com.apple.dock", "com.apple.loginwindow", "com.apple.systemuiserver",
        "com.apple.WindowServer", "com.apple.controlcenter", "com.apple.notificationcenterui",
        "com.ishaanpilar.CloseQuit", "com.ishaanpilar.CloseQuitSettings",
    ]

    static let url = URL(fileURLWithPath: NSHomeDirectory() + "/.config/closequit/config.json")

    // MARK: - Resolved values (the daemon reads only these)

    var effectiveExcluded: Set<String> {
        var s = exclude.map(Set.init) ?? Config.defaultExcluded
        s.formUnion(alsoExclude ?? [])
        return s
    }

    var effectiveOnly: Set<String>? {
        guard let only, !only.isEmpty else { return nil }
        return Set(only)
    }

    var effectivePollInterval: Double { max(0.2, pollInterval ?? 0.8) }
    var effectiveZeroReadings: Int { max(1, zeroReadingsRequired ?? 3) }

    /// Glob matching, so a rule can cover a whole vendor: `com.microsoft.*`.
    /// Only `*` is special, and it matches across dots.
    static func matches(pattern: String, bundleID: String) -> Bool {
        guard pattern.contains("*") else { return pattern == bundleID }
        if pattern == "*" { return true }
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        guard let re = try? NSRegularExpression(pattern: "^" + escaped + "$") else { return false }
        return re.firstMatch(in: bundleID,
                             range: NSRange(location: 0, length: bundleID.utf16.count)) != nil
    }

    static func firstMatch(in patterns: some Sequence<String>, _ bundleID: String) -> String? {
        // Longest pattern first, so a specific rule beats a broad one.
        patterns.sorted { $0.count > $1.count }
            .first { matches(pattern: $0, bundleID: bundleID) }
    }

    /// Why an app is or is not watched. Carrying the reason rather than a bare Bool is
    /// what makes the log and `--list` answer "why didn't it quit X?" without guesswork.
    struct Verdict {
        let managed: Bool
        let reason: String
        /// The wildcard rule responsible, when one is. A concrete bundle ID is nil here,
        /// because only wildcards need to be explained — and protected from the checkbox UI.
        let pattern: String?
    }

    func verdict(for bundleID: String) -> Verdict {
        if Config.hardExcluded.contains(bundleID) {
            return Verdict(managed: false, reason: "never quit", pattern: nil)
        }
        if let only = effectiveOnly {
            guard let hit = Config.firstMatch(in: only, bundleID) else {
                return Verdict(managed: false, reason: "not in allowlist", pattern: nil)
            }
            return Verdict(managed: true, reason: "allowlisted", pattern: hit.contains("*") ? hit : nil)
        }
        if let hit = Config.firstMatch(in: effectiveExcluded, bundleID) {
            return Verdict(managed: false,
                           reason: hit.contains("*") ? "excluded by \(hit)" : "excluded",
                           pattern: hit.contains("*") ? hit : nil)
        }
        return Verdict(managed: true, reason: "watched", pattern: nil)
    }

    /// True when an app is one the daemon will quit on last-window-close.
    func manages(_ bundleID: String) -> Bool { verdict(for: bundleID).managed }

    /// The wildcard rules currently in force, for the settings UI to show and edit.
    var patterns: [String] {
        let source = (effectiveOnly != nil) ? Set(only ?? []) : effectiveExcluded
        return source.filter { $0.contains("*") }.sorted()
    }

    // MARK: - Reading and writing

    static func load() -> Config {
        guard let data = try? Data(contentsOf: url),
              let c = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return c
    }

    /// Atomic, so the daemon polling this file never reads it half-written.
    func save() throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try e.encode(self).write(to: Config.url, options: .atomic)
    }

    static func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    // MARK: - Mutation

    /// Express a desired exclusion set the least surprising way: as additions to the
    /// defaults when it still contains them, and only otherwise as a full override.
    /// Without this, unchecking one default app would silently drop all the others.
    mutating func setExcluded(_ desired: Set<String>) {
        if desired.isSuperset(of: Config.defaultExcluded) {
            exclude = nil
            let extra = desired.subtracting(Config.defaultExcluded).sorted()
            alsoExclude = extra.isEmpty ? nil : extra
        } else {
            exclude = desired.sorted()
            alsoExclude = nil
        }
    }

    mutating func setOnly(_ desired: Set<String>?) {
        guard let desired, !desired.isEmpty else { only = nil; return }
        only = desired.sorted()
    }
}
