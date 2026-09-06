#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zig_version=$(zig version)

case "$zig_version" in
    0.16.*) ;;
    *)
        echo "error: Vivi requires Zig 0.16.x; found $zig_version" >&2
        exit 1
        ;;
esac

case "${CONFIGURATION:-Debug}" in
    Debug) optimize=Debug ;;
    *) optimize=ReleaseSafe ;;
esac

deployment_target=${MACOSX_DEPLOYMENT_TARGET:-14.0}
architectures=${ARCHS:-$(uname -m)}
staging_root="${DERIVED_FILE_DIR:-${TMPDIR:-/tmp}/vivi-derived}/vivi-backend"
output_dir=${BUILT_PRODUCTS_DIR:?BUILT_PRODUCTS_DIR is required}
output="$output_dir/libvivi_backend.a"
inputs=

mkdir -p "$staging_root" "$output_dir"

for architecture in $architectures; do
    case "$architecture" in
        arm64) zig_arch=aarch64 ;;
        x86_64) zig_arch=x86_64 ;;
        *)
            echo "error: unsupported Xcode architecture: $architecture" >&2
            exit 1
            ;;
    esac

    prefix="$staging_root/$CONFIGURATION/$architecture"
    zig build \
        --build-file "$repo_root/build.zig" \
        install-c-api \
        -Dtarget="$zig_arch-macos.$deployment_target" \
        -Doptimize="$optimize" \
        --prefix "$prefix"
    xcrun ranlib "$prefix/lib/libvivi_backend.a"
    inputs="$inputs $prefix/lib/libvivi_backend.a"
done

temporary="$output.tmp"
set -- $inputs
if [ "$#" -eq 1 ]; then
    cp "$1" "$temporary"
else
    xcrun lipo -create "$@" -output "$temporary"
fi
xcrun ranlib "$temporary"
mv "$temporary" "$output"
