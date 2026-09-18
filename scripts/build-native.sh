#!/bin/sh
set -eu

if [ "$(uname -s)" != Darwin ]; then
    echo "error: zig build native requires macOS and Xcode" >&2
    exit 1
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

exec xcodebuild \
    -project macos/Vivi.xcodeproj \
    -scheme Vivi \
    -configuration Debug \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    build
