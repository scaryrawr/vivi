#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

zig fmt --check build.zig backend cli
zig build test
zig build
zig build run -- --help >/dev/null
zig build run -- --version >/dev/null

zig build install-c-api \
    -Dtarget=x86_64-linux-gnu \
    -Dbackend-linkage=dynamic \
    --prefix zig-out/cross/linux-x86_64
zig build install-c-api \
    -Dtarget=x86_64-windows-msvc \
    -Dbackend-linkage=dynamic \
    --prefix zig-out/cross/windows-x86_64
# Zig 0.16 Debug hits a libubsan compiler error for this cross target.
zig build install-c-api \
    -Dtarget=aarch64-windows-msvc \
    -Dbackend-linkage=dynamic \
    -Doptimize=ReleaseSafe \
    --prefix zig-out/cross/windows-aarch64

xcrun swift-format lint --strict --recursive macos/Vivi macos/ViviTests
xcodebuild \
    -project macos/Vivi.xcodeproj \
    -scheme Vivi \
    -configuration Debug \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    test
