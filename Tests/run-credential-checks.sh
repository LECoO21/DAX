#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
check_directory="$(mktemp -d /private/tmp/dax-credential-check.XXXXXX)"
test_account="$(uuidgen)"
created=false
host="$check_directory/DAX.app"
untrusted="$check_directory/Untrusted.app"
identity="909A66D494EACC5C5B7D41181813E7A7C4854D9A"
keychain="$project_root/.signing/dax-signing.keychain-db"
credential_helper="$(scripts/build-credential-helper.sh)"
security unlock-keychain -p "$(cat "$project_root/.signing/keychain-password.txt")" "$keychain"
helper_hash="$(shasum -a 256 "$credential_helper" | cut -d ' ' -f 1)"
cleanup() {
    if [[ "$created" == true && -x "$host/Contents/MacOS/CredentialChecks" ]]; then
        "$host/Contents/MacOS/CredentialChecks" delete "$test_account" || true
    fi
    rm -r "$check_directory"
}
trap cleanup EXIT
mkdir -p "$host/Contents/MacOS" "$host/Contents/Helpers"
cp "$credential_helper" "$host/Contents/Helpers/DAXCredentials"
python3 - "$host/Contents/Info.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'wb') as f:
    plistlib.dump({'CFBundleIdentifier':'com.leco.dax','CFBundleExecutable':'CredentialChecks','CFBundlePackageType':'APPL'},f)
PY
xcrun swiftc -parse-as-library Sources/DAX/KeychainAccess.swift Tests/CredentialHelperChecks.swift -o "$host/Contents/MacOS/CredentialChecks"
codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$host"
original_hash="$(shasum -a 256 "$host/Contents/MacOS/CredentialChecks" | cut -d ' ' -f 1)"
"$host/Contents/MacOS/CredentialChecks" write "$test_account"
created=true
"$host/Contents/MacOS/CredentialChecks" read "$test_account"

xcrun swiftc -DUPDATED_HOST -parse-as-library Sources/DAX/KeychainAccess.swift Tests/CredentialHelperChecks.swift -o "$host/Contents/MacOS/CredentialChecks"
codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$host"
updated_hash="$(shasum -a 256 "$host/Contents/MacOS/CredentialChecks" | cut -d ' ' -f 1)"
[[ "$original_hash" != "$updated_hash" ]]
[[ "$helper_hash" == "$(shasum -a 256 "$host/Contents/Helpers/DAXCredentials" | cut -d ' ' -f 1)" ]]
"$host/Contents/MacOS/CredentialChecks" read "$test_account"

ditto "$host" "$untrusted"
codesign --force --sign - "$untrusted"
"$untrusted/Contents/MacOS/CredentialChecks" deny "$test_account"
"$host/Contents/MacOS/CredentialChecks" read "$test_account"
printf 'PASS stable helper survives main-app update and rejects an untrusted caller\n'
