#!/bin/sh
# Runs the tests in tests/main.swift. Needs Apple's Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"

OUT=../build/macos-tests
mkdir -p "$OUT"
swiftc -o "$OUT/jog-scroll-tests" $(ls *.swift | grep -v '^main\.swift$') tests/main.swift \
    -framework AppKit -framework CoreMIDI -framework ApplicationServices -framework UserNotifications
"$OUT/jog-scroll-tests"
