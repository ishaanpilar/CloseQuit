import Foundation

func check(_ ok: Bool, _ what: String) {
    print((ok ? "PASS  " : "FAIL  ") + what)
    if !ok { exit(1) }
}

// Round-trip: adding an app on top of the defaults must use alsoExclude.
var c = Config()
var desired = Config.defaultExcluded
desired.insert("com.figma.Desktop")
c.setExcluded(desired)
check(c.exclude == nil, "adding to defaults leaves `exclude` absent")
check(c.alsoExclude == ["com.figma.Desktop"], "adding to defaults writes alsoExclude")
check(c.effectiveExcluded == desired, "effectiveExcluded round-trips the addition")

// Removing one default must switch to an explicit full list, or the other
// defaults would silently come back.
var d = c
var fewer = c.effectiveExcluded
fewer.remove("com.apple.mail")
d.setExcluded(fewer)
check(d.alsoExclude == nil, "removing a default clears alsoExclude")
check(d.exclude != nil, "removing a default writes an explicit exclude list")
check(d.effectiveExcluded == fewer, "effectiveExcluded round-trips the removal")
check(!d.effectiveExcluded.contains("com.apple.mail"), "the removed default stays removed")
check(d.effectiveExcluded.contains("com.apple.finder"), "the other defaults survive")

// manages()
check(!c.manages("com.apple.finder"), "a default-excluded app is not managed")
check(c.manages("com.apple.Safari"), "an unlisted app is managed in exclude mode")

// Allowlist wins over exclusions, and an empty one means 'no allowlist'.
var e = Config()
e.only = ["com.apple.Safari"]
check(e.manages("com.apple.Safari"), "allowlisted app is managed")
check(!e.manages("com.apple.TextEdit"), "non-allowlisted app is not managed")
e.only = []
check(e.effectiveOnly == nil, "an empty allowlist is treated as absent")
check(e.manages("com.apple.TextEdit"), "empty allowlist falls back to exclude mode")

// Defaults when the file is absent or junk.
check(Config().effectivePollInterval == 0.8, "default poll interval")
check(Config().effectiveZeroReadings == 3, "default zero readings")
var f = Config(); f.pollInterval = 0.01; f.zeroReadingsRequired = 0
check(f.effectivePollInterval == 0.2, "poll interval is floored")
check(f.effectiveZeroReadings == 1, "zero readings is floored")

// Encoding must omit absent keys rather than writing nulls.
let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
let json = String(data: try! enc.encode(Config()), encoding: .utf8)!
check(json == "{}", "an untouched config encodes to {} — got \(json)")

// Wildcards.
check(Config.matches(pattern: "com.microsoft.*", bundleID: "com.microsoft.Word"), "glob matches a vendor prefix")
check(!Config.matches(pattern: "com.microsoft.*", bundleID: "com.apple.Pages"), "glob does not overmatch")
check(Config.matches(pattern: "*", bundleID: "anything"), "bare * matches everything")
check(Config.matches(pattern: "com.apple.Safari", bundleID: "com.apple.Safari"), "exact pattern still works")
check(!Config.matches(pattern: "com.a*e.Mail", bundleID: "com.apple.Mailbox"), "glob is anchored at both ends")
check(Config.matches(pattern: "com.a*e.Mail", bundleID: "com.apple.Mail"), "glob matches across dots")

var w = Config()
w.alsoExclude = ["com.microsoft.*"]
check(!w.manages("com.microsoft.Excel"), "a wildcard exclusion applies")
check(w.verdict(for: "com.microsoft.Excel").pattern == "com.microsoft.*", "the responsible pattern is reported")
check(w.manages("com.apple.Safari"), "the wildcard does not leak to other apps")
check(w.patterns == ["com.microsoft.*"], "patterns are surfaced for the UI")

// Longest pattern wins, so a specific rule beats a broad one.
var lp = Config()
lp.only = ["com.microsoft.*", "com.microsoft.Word.helper"]
check(Config.firstMatch(in: lp.only!, "com.microsoft.Word.helper") == "com.microsoft.Word.helper",
      "the more specific pattern is chosen")

// Hard exclusions cannot be opted into, even through an allowlist.
var h = Config()
h.only = ["com.apple.dock", "com.apple.Safari"]
check(!h.manages("com.apple.dock"), "an allowlisted hard exclusion is still refused")
check(h.verdict(for: "com.apple.dock").reason == "never quit", "hard exclusion says why")
check(h.manages("com.apple.Safari"), "the rest of the allowlist still works")
var h2 = Config()
h2.exclude = []
check(!h2.manages("com.ishaanpilar.CloseQuit"), "CloseQuit cannot be told to quit itself")

// Verdict reasons.
check(Config().verdict(for: "com.apple.Safari").reason == "watched", "watched reason")
check(Config().verdict(for: "com.apple.finder").reason == "excluded", "excluded reason")
check(h.verdict(for: "com.apple.TextEdit").reason == "not in allowlist", "allowlist-miss reason")

print("\nall config tests passed")
