#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root"

./scripts/check-zig.sh
./scripts/check-c-api-cross.sh
./scripts/check-macos.sh
