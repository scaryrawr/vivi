#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_root/web"

command -v pnpm >/dev/null 2>&1 || {
  echo "pnpm is required to check the web presentation" >&2
  exit 1
}

pnpm install --frozen-lockfile
pnpm typecheck
pnpm lint
pnpm format
pnpm test
pnpm build
pnpm storybook:build
pnpm playwright
