#!/bin/bash
set -euo pipefail

if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
    printf 'The native Notepad tests require macOS 13 or later.\n' >&2
    exit 1
fi

repository_directory="$(cd -- "$(/usr/bin/dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_build_directory="${repository_directory}/build/tests"
/bin/mkdir -p "$test_build_directory"

/usr/bin/xcrun --sdk macosx clang \
    -fobjc-arc -fblocks -O0 -g -Wall -mmacosx-version-min=13.0 \
    -I "${repository_directory}/Sources" \
    "${repository_directory}/Tests/NotepadTests.m" \
    "${repository_directory}/Sources/LiveEditor.m" \
    "${repository_directory}/Sources/EditorTypography.m" \
    "${repository_directory}/Sources/LiveFormatting.m" \
    "${repository_directory}/Sources/LiveMarkdown.m" \
    "${repository_directory}/Sources/TaskListEditing.m" \
    "${repository_directory}/Sources/SessionStore.m" \
    -framework AppKit -framework Foundation \
    -o "${test_build_directory}/NotepadTests"

"${test_build_directory}/NotepadTests"
