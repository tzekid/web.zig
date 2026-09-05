#!/usr/bin/env bash
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
zig=${ZIG:-zig}
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
hash=$(ZIG_GLOBAL_CACHE_DIR="$work/cache" "$zig" fetch "$root")
mkdir "$work/source"
tar -xzf "$work/cache/p/$hash.tar.gz" -C "$work/source" --strip-components=1
cd "$work/source"
"$zig" build test journeys consumer -Doptimize=ReleaseSafe --summary all
