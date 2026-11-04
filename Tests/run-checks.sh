#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/dax-checks.XXXXXX")"
trap 'rm -r "$check_directory"' EXIT
bash Tests/run-model-checks.sh
bash Tests/run-credential-checks.sh
bash Tests/Native/run-native-smoke.sh
xcrun swiftc -swift-version 5 -parse-as-library Sources/DAX/NativeCapture.swift Tests/Native/CaptureCompositionChecks.swift -o "$check_directory/capture-checks"
"$check_directory/capture-checks"
xcrun swiftc -swift-version 5 -parse-as-library Sources/DAX/NativeCapture.swift Tests/Native/SelectionPresentationChecks.swift -o "$check_directory/selection-checks"
"$check_directory/selection-checks"
xcrun swiftc -swift-version 5 -parse-as-library Sources/DAX/Models.swift Sources/DAX/Languages.swift Sources/DAX/KeychainAccess.swift Sources/DAX/Services.swift Tests/ServicesChecks.swift -o "$check_directory/service-checks"
"$check_directory/service-checks"
xcrun swiftc -swift-version 5 -parse-as-library Sources/DAX/Models.swift Sources/DAX/Storage.swift Tests/StorageChecks.swift -o "$check_directory/storage-checks"
"$check_directory/storage-checks"
bash Tests/run-plugin-checks.sh
xcrun swiftc -swift-version 5 -parse-as-library Tests/RichRendererChecks.swift -o "$check_directory/renderer-checks"
"$check_directory/renderer-checks" "$PWD/Sources/DAX/Resources/Web/render.html"
