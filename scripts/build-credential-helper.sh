#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_file="$project_root/Sources/DAXCredentials/main.swift"
helper_directory="$project_root/.signing/credentials-helper"
helper="$helper_directory/DAXCredentials"
source_hash="$(shasum -a 256 "$source_file" | cut -d ' ' -f 1)"
identity="909A66D494EACC5C5B7D41181813E7A7C4854D9A"
keychain="$project_root/.signing/dax-signing.keychain-db"

if [[ -f "$helper" && -f "$helper_directory/source.sha256" ]] &&
   [[ "$(cat "$helper_directory/source.sha256")" == "$source_hash" ]] &&
   codesign --verify --strict -R '=identifier "com.leco.dax.credentials-helper" and certificate root = H"909a66d494eacc5c5b7d41181813e7a7c4854d9a"' "$helper" 2>/dev/null; then
    printf '%s\n' "$helper"
    exit 0
fi
mkdir -p "$helper_directory"
staging="$(mktemp -d /private/tmp/dax-credentials-build.XXXXXX)"
xcrun swiftc -O -suppress-warnings -target "$(uname -m)-apple-macos15.0" "$source_file" -o "$staging/DAXCredentials"
security unlock-keychain -p "$(cat "$project_root/.signing/keychain-password.txt")" "$keychain"
codesign --force --sign "$identity" --identifier com.leco.dax.credentials-helper --keychain "$keychain" --timestamp=none "$staging/DAXCredentials"
codesign --verify --strict "$staging/DAXCredentials"
cp "$staging/DAXCredentials" "$helper"
printf '%s\n' "$source_hash" > "$helper_directory/source.sha256"
printf '%s\n' "$helper"
