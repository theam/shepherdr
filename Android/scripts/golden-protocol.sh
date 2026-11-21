#!/bin/sh
# Writes the protocol fixture Android's tests read from the Mac's own Swift code
# (Sources/ShepherdrRemote), so the two sides can't drift apart unnoticed. Needs macOS and Swift.
# With --check, fails when the fixture in the repository is out of date instead of writing it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
fixture="$here/../app/src/test/resources/golden-protocol.txt"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$here/GoldenProtocol.swift" "$work/main.swift"
swiftc -O "$work/main.swift" "$repo"/Sources/ShepherdrRemote/*.swift -o "$work/golden"
"$work/golden" > "$work/golden-protocol.txt"
if [ "${1:-}" = "--check" ]; then
  diff -u "$fixture" "$work/golden-protocol.txt"
else
  cp "$work/golden-protocol.txt" "$fixture"
fi
