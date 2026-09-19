#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
web_root="$repo_root/web"
output="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ViviWebAssets"

command -v pnpm >/dev/null 2>&1 || {
  echo "pnpm is required to build the test-only WebKit host assets" >&2
  exit 1
}

cd "$web_root"
[ -d node_modules ] || {
  echo "web dependencies are missing; run 'cd web && pnpm install --frozen-lockfile' before Xcode tests" >&2
  exit 1
}
pnpm build:native

rm -rf "$output"
mkdir -p "$output"
cp -R dist-native/. "$output/"

(
  cd "$output"
  find . -type f ! -name asset-manifest.json -print \
    | LC_ALL=C sort \
    | sed 's#^\./##' \
    | while IFS= read -r file; do
        digest=$(shasum -a 256 "$file" | awk '{print $1}')
        printf '%s\t%s\n' "$file" "$digest"
      done \
    | python3 -c 'import json,sys; print(json.dumps(dict(line.rstrip("\n").split("\t",1) for line in sys.stdin), sort_keys=True, separators=(",",":")))'
) > "$output/asset-manifest.json"
