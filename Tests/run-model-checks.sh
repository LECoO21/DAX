#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/dax-model-check.XXXXXX")"
cd "$project_root"
# Plugin workers resolve the bridge from the source tree. Rich rendering has a separate check.
cat > "$check_directory/ResourceBundle.swift" <<'SWIFT'
import Foundation
extension Bundle { static let module = Bundle.main }
SWIFT
sources=()
for source in Sources/DAX/*.swift; do
    if [[ "$source" != "Sources/DAX/main.swift" ]]; then sources+=("$source"); fi
done
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos15.0 \
    "${sources[@]}" "$check_directory/ResourceBundle.swift" Tests/ModelTests/ModelChecks.swift \
    -o "$check_directory/model-checks"
"$check_directory/model-checks"
