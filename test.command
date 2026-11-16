#!/bin/zsh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT/build.nosync"
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.2" \
    "$ROOT/Sources/AppResolver.swift" \
    "$ROOT/Sources/CoreAudioReader.swift" \
    "$ROOT/Sources/AudioMonitor.swift" \
    "$ROOT/Sources/SoundLogStream.swift" \
    "$ROOT/Tests/MonitorTests.swift" \
    -framework AppKit -framework CoreAudio -lproc \
    -o "$ROOT/build.nosync/MonitorTests"
"$ROOT/build.nosync/MonitorTests"
