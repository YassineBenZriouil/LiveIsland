#!/bin/bash
# Runs the test suite. With only the Command Line Tools installed, the Swift Testing macro
# plugin, framework and runtime library live in folders the compiler and loader don't search
# by default, so point them there.
set -euo pipefail
cd "$(dirname "$0")/.."

TOOLS="$(xcode-select -p)"
ARGS=()
PLUGINS="$TOOLS/usr/lib/swift/host/plugins/testing"
FRAMEWORKS="$TOOLS/Library/Developer/Frameworks"
LIBS="$TOOLS/Library/Developer/usr/lib"
[ -d "$PLUGINS" ] && ARGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
[ -d "$FRAMEWORKS/Testing.framework" ] && ARGS+=(-Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS")
[ -f "$LIBS/lib_TestingInterop.dylib" ] && ARGS+=(-Xlinker -rpath -Xlinker "$LIBS")
exec swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
