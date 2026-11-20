#!/usr/bin/env bash
# Command Line Tools ship the Swift Testing macro plugin outside the default search path.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift test -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
