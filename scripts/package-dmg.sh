#!/bin/bash
set -euo pipefail

fail() { printf '%s\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || fail 'Build the disk image on macOS 13 or later.'
release=false
case "$#:${1:-}" in
    0:) ;;
    1:--release) release=true ;;
    *) fail 'Usage: scripts/package-dmg.sh [--release]' ;;
esac

project_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_directory/Resources/Info.plist")"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]] || fail 'Expected a numeric app version in Info.plist.'
build_directory="$project_directory/build"
filename="Notepad-${version}-preview.dmg"
if [[ "$release" == true ]]; then
    [[ -n "${NOTEPAD_SIGN_IDENTITY:-}" ]] || fail 'Set NOTEPAD_SIGN_IDENTITY to your Developer ID Application identity.'
    [[ -n "${NOTEPAD_NOTARY_PROFILE:-}" ]] || fail 'Set NOTEPAD_NOTARY_PROFILE to your notarytool Keychain profile name.'
    filename="Notepad-${version}.dmg"
fi

mkdir -p "$build_directory"
output="$build_directory/$filename"
[[ ! -d "$output" && ! -L "$output" ]] || fail "Move the existing directory or link at $output before packaging."
work="$(mktemp -d "$build_directory/.notepad-dmg.XXXXXXXX")"
contents="$work/contents"
app="$contents/Notepad.app"
image="$work/$filename"
mountpoint="$work/mounted"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]] && ! hdiutil detach "$mountpoint" >/dev/null; then
        printf 'Could not eject the disk image at %s. Temporary files are in %s.\n' "$mountpoint" "$work" >&2
        return
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir "$contents" "$mountpoint"
"$project_directory/scripts/build.sh" --universal "$app"
ln -s /Applications "$contents/Applications"

if [[ "$release" == true ]]; then
    codesign --force --options runtime --timestamp --sign "$NOTEPAD_SIGN_IDENTITY" "$app"
    # Apple's Developer ID Application certificate extension.
    codesign --verify --strict --all-architectures \
        -R='anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' "$app"
fi
hdiutil create -fs HFS+ -volname Notepad -srcfolder "$contents" -format UDZO "$image"
if [[ "$release" == true ]]; then
    codesign --timestamp --sign "$NOTEPAD_SIGN_IDENTITY" "$image"
    xcrun notarytool submit "$image" --keychain-profile "$NOTEPAD_NOTARY_PROFILE" \
        --wait --output-format plist > "$work/submission.plist"
    status="$(/usr/libexec/PlistBuddy -c 'Print :status' "$work/submission.plist")"
    if [[ "$status" != Accepted ]]; then
        submission="$(/usr/libexec/PlistBuddy -c 'Print :id' "$work/submission.plist")"
        fail "Apple notarization returned $status for submission $submission. Review its notarytool log."
    fi
    xcrun stapler staple "$image"
    xcrun stapler validate "$image"
    spctl --assess --type open --context context:primary-signature "$image"
fi

hdiutil verify "$image"
hdiutil attach -nobrowse -readonly -mountpoint "$mountpoint" "$image"
mounted=true
[[ "$(readlink "$mountpoint/Applications")" == /Applications ]] || fail 'The disk image is missing its Applications shortcut.'
codesign --verify --strict --all-architectures "$mountpoint/Notepad.app"
xcrun lipo "$mountpoint/Notepad.app/Contents/MacOS/Notepad" -verify_arch arm64 x86_64
hdiutil detach "$mountpoint"
mounted=false
mv -f "$image" "$output"
printf 'Created %s\n' "$output"
