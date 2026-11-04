#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${DAX_BUILD_ROOT:-/private/tmp/dax-swift-build}"
output_root="${DAX_OUTPUT_ROOT:-/private/tmp/dax-package}"
configuration="${DAX_CONFIGURATION:-debug}"
identity="909A66D494EACC5C5B7D41181813E7A7C4854D9A"
keychain="$project_root/.signing/dax-signing.keychain-db"
if [[ ! -f "$keychain" || ! -f "$project_root/.signing/keychain-password.txt" ]]; then
    echo "缺少项目的稳定签名身份。请恢复原 .signing 目录后构建。" >&2
    exit 1
fi
cd "$project_root"
swift build --scratch-path "$build_root" -c "$configuration"
binary_root="$(swift build --scratch-path "$build_root" -c "$configuration" --show-bin-path)"
mkdir -p "$output_root"
staging="$(mktemp -d "$output_root/staging.XXXXXX")"
app="$staging/DAX.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
credential_helper="$("$project_root/scripts/build-credential-helper.sh")"
cp "$credential_helper" "$app/Contents/Helpers/DAXCredentials"
codesign --verify --strict "$app/Contents/Helpers/DAXCredentials"
cp "$binary_root/DAX" "$app/Contents/MacOS/DAX"
ditto --norsrc --noextattr "$binary_root/DAX_DAX.bundle" "$app/Contents/Resources/DAX_DAX.bundle"
cp "$project_root/Sources/DAX/Resources/DAX.sdef" "$app/Contents/Resources/DAX.sdef"
cp "$project_root/Sources/DAX/Resources/Branding/DAX.icns" "$app/Contents/Resources/DAX.icns"
/usr/bin/python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as file:
    plistlib.dump({
        'CFBundleIdentifier': 'com.leco.dax', 'CFBundleName': 'DAX',
        'CFBundleDisplayName': 'DAX', 'CFBundleExecutable': 'DAX',
        'CFBundleIconFile': 'DAX.icns',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '0.1.0',
        'CFBundleVersion': '1', 'LSMinimumSystemVersion': '15.0',
        'LSUIElement': True, 'NSHighResolutionCapable': True,
        'NSAppleScriptEnabled': True, 'OSAScriptingDefinition': 'DAX.sdef',
        'NSAppleEventsUsageDescription': 'DAX 使用自动化来读取用户选择的文字。',
        'CFBundleURLTypes': [{'CFBundleURLName': 'com.leco.dax', 'CFBundleURLSchemes': ['dax']}],
        'CFBundleDocumentTypes': [
            {'CFBundleTypeName': 'Bob Plugin', 'CFBundleTypeRole': 'Editor',
             'LSHandlerRank': 'Alternate', 'CFBundleTypeExtensions': ['bobplugin']},
            {'CFBundleTypeName': 'Image', 'CFBundleTypeRole': 'Viewer',
             'LSHandlerRank': 'Alternate', 'LSItemContentTypes': ['public.image']}
        ]
    }, file)
PY
xattr -cr "$app"
security unlock-keychain -p "$(cat "$project_root/.signing/keychain-password.txt")" "$keychain"
codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$app/Contents/Resources/DAX_DAX.bundle"
codesign --force --sign "$identity" --keychain "$keychain" --timestamp=none "$app"
codesign --verify --deep --strict "$app"
codesign -d -r- "$app" > "$staging/designated-requirement.txt" 2>/dev/null
echo "签名应用已生成 $app"
if [[ "${1:-}" == "--install" ]]; then
    destination="/Applications/DAX.app"
    if pgrep -x DAX >/dev/null; then
        echo "DAX 正在运行。请退出后重新安装，构建包已保留。" >&2
        exit 1
    fi
    mkdir -p "/Applications"
    if [[ -e "$destination/Contents" ]]; then
        # Custom file icons carry Finder metadata. Clear it for strict package verification.
        xcrun swift "$project_root/scripts/apply-app-icon.swift" "$destination" --clear
        # Keep the outer .app directory stable so Finder and permission bookmarks retain its location.
        mv "$destination/Contents" "$staging/previous-Contents"
    fi
    mkdir -p "$destination"
    if ! ditto --norsrc --noextattr "$app/Contents" "$destination/Contents" || ! codesign --verify --deep --strict "$destination"; then
        if [[ -e "$destination/Contents" ]]; then mv "$destination/Contents" "$staging/incomplete-Contents"; fi
        if [[ -e "$staging/previous-Contents" ]]; then
            mv "$staging/previous-Contents" "$destination/Contents"
            xcrun swift "$project_root/scripts/apply-app-icon.swift" "$destination" || true
        fi
        exit 1
    fi
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"
    xcrun swift "$project_root/scripts/apply-app-icon.swift" "$destination"
    codesign --verify --deep "$destination"
    echo "已安装 $destination"
fi
