#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

zig build -Dtarget=x86_64-linux-gnu --prefix zig-out/cli-linux
zig build -Dtarget=x86_64-windows-gnu --prefix zig-out/cli-windows-x86_64
zig build -Dtarget=aarch64-windows-gnu -Doptimize=ReleaseSafe \
    --prefix zig-out/cli-windows-aarch64
