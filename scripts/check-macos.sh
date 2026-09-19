#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

xcrun swift-format lint --strict --recursive \
    macos/Vivi \
    macos/ViviTests \
    macos/ViviWebHostTests
xcodebuild \
    -project macos/Vivi.xcodeproj \
    -scheme Vivi \
    -configuration Debug \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    test
xcodebuild \
    -project macos/Vivi.xcodeproj \
    -scheme ViviWebHostTests \
    -configuration Debug \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    test
