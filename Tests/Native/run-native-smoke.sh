#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/../.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/dax-native-check.XXXXXX")"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
  "$project_root/Sources/DAX/NativeCapture.swift" \
  "$project_root/Tests/Native/NativeSmoke.swift" \
  -o "$check_directory/native-smoke"
"$check_directory/native-smoke"
