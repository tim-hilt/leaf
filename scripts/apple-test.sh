#!/usr/bin/env bash
# Usage: scripts/apple-test.sh <xcodebuild args>, e.g. -destination ... -only-testing:...
# Runs the LeafPDF scheme's tests and prints only compile errors and the test
# output (failures, prints and the summary); the full log stays in $LOG.
# Failure diagnostics are off: collecting them takes ~10 minutes per failing run.

set -uo pipefail
LOG=${LOG:-/tmp/leafpdf-test.log}

cd "$(dirname "$0")/../apple" || exit 1
xcodebuild -scheme LeafPDF test -collect-test-diagnostics never "$@" >"$LOG" 2>&1
status=$?

awk -v zwsp="$(printf '\342\200\213')" '
    index($0, zwsp) == 1 { $0 = substr($0, length(zwsp) + 1) }  # Swift Testing prefixes some lines
    /^[0-9-]+ [0-9:.+]+ [A-Za-z]+\[[0-9]+:[0-9]+\]/ { next }  # xcodebuild and system logs
    /Test run started/ { testing = 1; next }
    /^✔ Test run / { print; next }
    /^(◇ |✔ (Test|Suite) |↳ (Testing Library|Target Platform))/ { next }  # progress and passes
    /^Test session results/ { testing = 0 }
    testing || /: error: / || /^\*\* .* \*\*$/ { print }
' "$LOG"
[ $status -eq 0 ] || echo "Full log: $LOG"
exit $status
