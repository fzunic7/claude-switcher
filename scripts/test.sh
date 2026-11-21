#!/usr/bin/env bash
# Command Line Tools ship the Swift Testing macro plugin outside the default search path.
set -euo pipefail
cd "$(dirname "$0")/.."
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
# Full Xcode finds the plugin itself; only pass the path when building with the Command Line Tools.
if [[ "$(xcode-select -p)" == *CommandLineTools* && -d "$PLUGINS" ]]; then
  exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
