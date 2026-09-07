#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

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
