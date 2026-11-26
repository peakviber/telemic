#!/bin/bash
# Unit tests for the core logic, then the app's end-to-end self-test.
# The self-test never feeds the real RemoteMic driver, so it is safe while the mic is in use.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

CORE=(App/Sources/Protocol.swift App/Sources/Net.swift App/Sources/Opus.swift
      App/Sources/Playout.swift App/Sources/Support.swift App/Sources/Receiver.swift)
swiftc -O -swift-version 5 -o build/unit-tests "${CORE[@]}" Tests/Unit/main.swift
./build/unit-tests

if [ -x build/RemoteMic.app/Contents/MacOS/RemoteMic ]; then
  echo
  build/RemoteMic.app/Contents/MacOS/RemoteMic --selftest
fi
