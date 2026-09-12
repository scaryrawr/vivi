#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

zig fmt --check build.zig backend cli
zig build test "$@"
zig build "$@"
zig build run "$@" -- --help >/dev/null
zig build run "$@" -- --version >/dev/null
