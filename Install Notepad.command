#!/bin/bash
set -euo pipefail

fail() {
    printf '\n%s\n' "$1" >&2
    exit 1
}

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
    fail 'Run this installer on your Mac.'
fi

macos_version="$(/usr/bin/sw_vers -productVersion)"
if (( ${macos_version%%.*} < 13 )); then
    fail 'Notepad requires macOS 13 Ventura or newer.'
fi

if ! /usr/bin/xcode-select -p >/dev/null 2>&1 ||
   ! /usr/bin/xcrun --find clang >/dev/null 2>&1; then
    fail 'Run xcode-select --install in Terminal. After Apple’s Command Line Tools finish installing, run this installer again.'
fi

source_directory="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
applications_directory="${HOME}/Applications"
destination="${applications_directory}/Notepad.app"
bundle_identifier='com.kudala.notepad'

check_destination() {
    local existing_identifier
    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        return
    fi
    if [[ -L "$destination" || ! -d "$destination" ]]; then
        fail "Move the existing item at ${destination} before installing."
    fi
    existing_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
        "${destination}/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_identifier" != "$bundle_identifier" ]]; then
        fail "A different app already occupies ${destination}. Move it before installing."
    fi
}

check_not_running() {
    local running
    running="$(/usr/bin/osascript -l JavaScript -e '
        function run(argv) {
            ObjC.import("AppKit");
            const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0]);
            return apps.count > 0;
        }
    ' "$bundle_identifier" 2>/dev/null)" || return 0
    if [[ "$running" == true ]]; then
        fail 'Quit Notepad with Command+Q so it saves your drafts, then run this installer again.'
    fi
}

check_destination
check_not_running
/bin/mkdir -p "$applications_directory"
staging_directory="$(/usr/bin/mktemp -d "${applications_directory}/.notepad-install.XXXXXXXX")"
staged_app="${staging_directory}/Notepad.app"
previous_directory="${staging_directory}/Previous"
previous_app="${previous_directory}/Notepad.app"
installation_complete=false

cleanup() {
    if [[ -d "$previous_app" && "$installation_complete" == false ]]; then
        if [[ -e "$destination" || -L "$destination" ]] ||
           ! /bin/mv "$previous_app" "$applications_directory/"; then
            printf 'Your previous app is at %s\n' "$previous_app" >&2
            return
        fi
    fi
    /bin/rm -rf "$staging_directory"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

"${source_directory}/scripts/build.sh" "$staged_app"

check_destination
check_not_running
if [[ -d "$destination" ]]; then
    /bin/mkdir "$previous_directory"
    /bin/mv "$destination" "$previous_directory/"
fi
/bin/mv "$staged_app" "$applications_directory/"
installation_complete=true

printf 'Installed at %s\n' "$destination"
/usr/bin/open "$destination"
