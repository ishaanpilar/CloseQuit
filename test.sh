#!/bin/bash
# Exercises the config model — the part with real branching, and the part that can
# silently corrupt a hand-written config if it gets the exclude/alsoExclude choice
# wrong. The daemon engine itself needs a live window server, so it is not covered
# here; see the live matrix in PLAN.md.
set -euo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="$(mktemp -d)/configtests"
swiftc -o "$BIN" "$SRC/Sources/Config.swift" "$SRC/Tests/main.swift"
"$BIN"
