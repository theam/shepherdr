#!/bin/bash
set -euo pipefail

tag="${1:?Usage: scripts/package-release.sh vMAJOR.MINOR.PATCH}"
if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "Expected a stable version tag such as v0.1.0." >&2
    exit 1
fi
version="${tag#v}"
build_number="${GITHUB_RUN_NUMBER:-1}"
if [[ ! "$build_number" =~ ^[1-9][0-9]*$ ]]; then
    echo "Build number must be a positive integer." >&2
    exit 1
fi

# Releases are signed with a Developer ID and notarized by Apple (see docs/RELEASING.md).
# Without an identity the packages get an ad hoc signature, which only suits local testing.
identity="${SHEPHERDR_SIGN_IDENTITY:-}"
if [[ -n "$identity" ]]; then
    team_id="${SHEPHERDR_TEAM_ID:?Set SHEPHERDR_TEAM_ID to the Apple team that owns the signing identity.}"
    notary=(--keychain-profile "${SHEPHERDR_NOTARY_PROFILE:?Set SHEPHERDR_NOTARY_PROFILE to a notarytool keychain profile.}")
    if [[ -n "${SHEPHERDR_NOTARY_KEYCHAIN:-}" ]]; then
        notary+=(--keychain "$SHEPHERDR_NOTARY_KEYCHAIN")
    fi
    if ! grep -Fq -- "$identity" <<< "$(security find-identity -v -p codesigning)"; then
        echo "No valid code signing identity matches $identity." >&2
        exit 1
    fi
else
    echo "SHEPHERDR_SIGN_IDENTITY is not set: packaging with an ad hoc signature, for local testing only." >&2
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
mkdir -p build dist
asset="Shepherdr-${version}-macos-arm64"
for extension in zip dmg; do
    if [[ -e "dist/$asset.$extension" ]]; then
        echo "Refusing to overwrite dist/$asset.$extension." >&2
        exit 1
    fi
done
work_dir="$(mktemp -d "$repo_root/build/package.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# Uploads a file for notarization, waits for Apple's verdict and stops unless it is accepted.
notarize() {
    local file="$1" result="$work_dir/notary.json" status id
    xcrun notarytool submit "$file" "${notary[@]}" --wait --timeout 30m --output-format json > "$result" || true
    status="$(plutil -extract status raw -o - "$result" 2>/dev/null || echo unknown)"
    if [[ "$status" != Accepted ]]; then
        echo "Notarization of ${file##*/} ended as $status." >&2
        cat "$result" >&2
        if id="$(plutil -extract id raw -o - "$result" 2>/dev/null)"; then
            xcrun notarytool log "$id" "${notary[@]}" >&2 || true
        fi
        exit 1
    fi
    echo "Apple notarized ${file##*/}."
}

# Asks Gatekeeper what a downloader's Mac would decide. Runners may have assessments
# disabled, in which case only the stapled ticket and the signature are checked.
assess() {
    local output
    output="$(spctl --assess --verbose=2 "$@" 2>&1)" || { echo "$output" >&2; return 1; }
    echo "$output"
    if [[ "$(spctl --status)" == 'assessments enabled' ]] && ! grep -Fq 'source=Notarized Developer ID' <<< "$output"; then
        echo "Gatekeeper does not accept it as notarized Developer ID software." >&2
        return 1
    fi
}

xcodebuild -project Shepherdr.xcodeproj -scheme Shepherdr \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$work_dir/DerivedData" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET=14.0 \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGNING_ALLOWED=NO build

app="$work_dir/DerivedData/Build/Products/Release/Shepherdr.app"
binary="$app/Contents/MacOS/Shepherdr"
plist="$app/Contents/Info.plist"
[[ "$(xcrun lipo -archs "$binary")" == arm64 ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build_number" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")" == 14.0 ]]

mkdir -p "$app/Contents/Resources"
cp LICENSE "$app/Contents/Resources/LICENSE"
# Keep the terminal renderer's MIT notices in every downloadable app, independently
# of SwiftPM's platform-specific resource bundle layout.
cp Sources/ShepherdrTerminalUI/Resources/SwiftTerm-LICENSE "$app/Contents/Resources/SwiftTerm-LICENSE"
# The bundled Fira Code fonts are distributed under the SIL Open Font License.
cp Sources/ShepherdrTerminalUI/Resources/Fonts/FiraCode-OFL.txt "$app/Contents/Resources/FiraCode-OFL.txt"
# FluidAudio (dictation) is Apache-2.0; its license travels with the binary.
cp Sources/ShepherdrDictation/Resources/FluidAudio-LICENSE "$app/Contents/Resources/FluidAudio-LICENSE"
# marked (Markdown rendering) is MIT.
cp Sources/ShepherdrCore/Resources/Markdown/marked-LICENSE "$app/Contents/Resources/marked-LICENSE"
# The entitlement lets the hardened runtime open the microphone for dictation.
if [[ -n "$identity" ]]; then
    # Notarization requires the hardened runtime and a secure timestamp.
    codesign --force --sign "$identity" --options runtime --timestamp --entitlements App/Shepherdr.entitlements "$app"
else
    # An ad hoc signature makes the arm64 bundle valid, but does not confer Developer ID trust.
    codesign --force --sign - --options runtime --timestamp=none --entitlements App/Shepherdr.entitlements "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

if [[ -n "$identity" ]]; then
    signature="$(codesign --display --verbose=2 "$app" 2>&1)"
    if ! grep -Fxq "TeamIdentifier=$team_id" <<< "$signature"; then
        echo "The app is not signed by team $team_id." >&2
        exit 1
    fi
    for expected in 'Authority=Developer ID Application: ' 'Timestamp=' '(runtime)'; do
        if ! grep -Fq -- "$expected" <<< "$signature"; then
            echo "The app signature lacks $expected" >&2
            exit 1
        fi
    done
    # Staple the app itself so the ZIP's copy opens offline too, then package the stapled app.
    ditto -c -k --keepParent "$app" "$work_dir/notarize.zip"
    notarize "$work_dir/notarize.zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    assess --type execute "$app"
fi

# Packages are assembled outside dist/ so a failed signature or notarization leaves nothing to upload.
ditto -c -k --sequesterRsrc --keepParent "$app" "$work_dir/$asset.zip"
mkdir "$work_dir/unpacked"
ditto -x -k "$work_dir/$asset.zip" "$work_dir/unpacked"
codesign --verify --deep --strict --verbose=2 "$work_dir/unpacked/Shepherdr.app"
cmp "$binary" "$work_dir/unpacked/Shepherdr.app/Contents/MacOS/Shepherdr"
cmp Sources/ShepherdrTerminalUI/Resources/SwiftTerm-LICENSE "$work_dir/unpacked/Shepherdr.app/Contents/Resources/SwiftTerm-LICENSE"
if [[ -n "$identity" ]]; then
    xcrun stapler validate "$work_dir/unpacked/Shepherdr.app"
fi

mkdir "$work_dir/dmg"
ditto "$app" "$work_dir/dmg/Shepherdr.app"
ln -s /Applications "$work_dir/dmg/Applications"
cp docs/INSTALL.txt "$work_dir/dmg/Install Shepherdr.txt"
hdiutil create -volname Shepherdr -srcfolder "$work_dir/dmg" \
    -format UDZO "$work_dir/$asset.dmg"
if [[ -n "$identity" ]]; then
    codesign --sign "$identity" --timestamp "$work_dir/$asset.dmg"
    codesign --verify --strict --verbose=2 "$work_dir/$asset.dmg"
    notarize "$work_dir/$asset.dmg"
    xcrun stapler staple "$work_dir/$asset.dmg"
    xcrun stapler validate "$work_dir/$asset.dmg"
    assess --type open --context context:primary-signature "$work_dir/$asset.dmg"
fi
hdiutil verify "$work_dir/$asset.dmg"

mv "$work_dir/$asset.zip" "$work_dir/$asset.dmg" dist/
cd dist
shasum -a 256 "$asset.dmg" "$asset.zip" > SHA256SUMS
shasum -a 256 -c SHA256SUMS
echo "Release packages are ready in $repo_root/dist"
