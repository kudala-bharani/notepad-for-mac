#!/bin/bash
set -euo pipefail

fail() {
    printf '\n%s\n' "$1" >&2
    exit 1
}

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
    fail 'Build Notepad on macOS 13 Ventura or newer.'
fi

macos_version="$(/usr/bin/sw_vers -productVersion)"
if (( ${macos_version%%.*} < 13 )); then
    fail 'Notepad requires macOS 13 Ventura or newer.'
fi

if ! /usr/bin/xcode-select -p >/dev/null 2>&1 ||
   ! /usr/bin/xcrun --find clang >/dev/null 2>&1; then
    fail 'Install Apple Command Line Tools with xcode-select --install, then run this build again.'
fi

if (( $# > 1 )); then
    fail 'Usage: scripts/build.sh [output/Notepad.app]'
fi

project_directory="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
output_app="${1:-${project_directory}/build/Notepad.app}"
if [[ "$output_app" != /* ]]; then
    output_app="${PWD}/${output_app}"
fi
if [[ "$output_app" != *.app || "$output_app" == */../* ]]; then
    fail 'Choose an output path ending in .app.'
fi
output_parent="$(/usr/bin/dirname -- "$output_app")"
output_name="$(/usr/bin/basename -- "$output_app")"
bundle_identifier='com.kudala.notepad'

check_output() {
    local existing_identifier
    if [[ ! -e "$output_app" && ! -L "$output_app" ]]; then
        return
    fi
    if [[ -L "$output_app" || ! -d "$output_app" ]]; then
        fail "Move the existing item at ${output_app} before building."
    fi
    existing_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "${output_app}/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_identifier" != "$bundle_identifier" ]]; then
        fail "A different app already occupies ${output_app}. Choose another output path."
    fi
}

check_output
/bin/mkdir -p "$output_parent"
staging_directory="$(/usr/bin/mktemp -d "${output_parent}/.notepad-build.XXXXXXXX")"
staged_app="${staging_directory}/${output_name}"
previous_app="${staging_directory}/previous.app"
build_complete=false

cleanup() {
    if [[ -d "$previous_app" && "$build_complete" == false ]]; then
        if [[ -e "$output_app" || -L "$output_app" ]] ||
           ! /bin/mv "$previous_app" "$output_app"; then
            printf 'Your previous build is at %s\n' "$previous_app" >&2
            return
        fi
    fi
    /bin/rm -rf "$staging_directory"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Building Notepad for this Mac…\n'
/bin/mkdir -p "${staged_app}/Contents/MacOS" "${staged_app}/Contents/Resources"
/bin/cp "${project_directory}/Resources/Info.plist" "${staged_app}/Contents/Info.plist"
/bin/cp "${project_directory}/Resources/Notepad.icns" "${staged_app}/Contents/Resources/Notepad.icns"

/usr/bin/xcrun --sdk macosx clang \
    -fobjc-arc -fblocks -O2 -Wall -mmacosx-version-min=13.0 \
    "${project_directory}/Sources/main.m" "${project_directory}/Sources/SessionStore.m" \
    "${project_directory}/Sources/LiveEditor.m" "${project_directory}/Sources/LiveFormatting.m" \
    "${project_directory}/Sources/LiveMarkdown.m" "${project_directory}/Sources/EditorTypography.m" \
    "${project_directory}/Sources/TaskListEditing.m" \
    -framework AppKit -framework Foundation \
    -o "${staged_app}/Contents/MacOS/Notepad"

/usr/bin/codesign --force --sign - "$staged_app"
/usr/bin/codesign --verify --strict "$staged_app"
check_output
if [[ -d "$output_app" ]]; then
    /bin/mv "$output_app" "$previous_app"
fi
/bin/mv "$staged_app" "$output_app"
build_complete=true
printf 'Built %s\n' "$output_app"
