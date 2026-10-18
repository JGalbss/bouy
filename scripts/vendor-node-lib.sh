#!/bin/sh
# Vendors Node's own built-in JavaScript, `lib/` of nodejs/node at the tag of `.node-version`,
# into runtime/vendor/node/lib, with Node's MIT LICENSE, and the bundled dependencies that lib/
# requires as internal/deps/<path> into runtime/vendor/node/deps, each with its license. crates/buoy-cli/build.rs compiles
# the ids of runtime/node/builtins.txt from there into the runtime (docs/design/node-builtins.md).
#
# The files stay byte-identical: Buoy's own version of an id goes into runtime/node/<id>.js,
# which build.rs takes in place of the vendored file. The script writes
# runtime/vendor/node/lib.sha256, one `shasum -a 256` line for each file, and the tag and the
# commit on its first line.
#
# This script runs no node.
#
# Usage: scripts/vendor-node-lib.sh

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
tag="v$(cat "$root/.node-version")"
vendor="$root/runtime/vendor/node"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "$0: fetching nodejs/node lib/ at $tag" >&2
git -C "$work" init -q
git -C "$work" remote add origin https://github.com/nodejs/node.git
deps="undici/undici.js undici/LICENSE acorn/acorn/dist/acorn.js acorn/acorn/LICENSE
acorn/acorn-walk/dist/walk.js acorn/acorn-walk/LICENSE minimatch/index.js minimatch/LICENSE.md"
patterns=$(for dep in $deps; do printf ' /deps/%s' "$dep"; done)
# $patterns splits into one pattern for each file on purpose.
git -C "$work" sparse-checkout set --no-cone /LICENSE /lib/ $patterns
git -C "$work" fetch -q --depth 1 --filter=blob:none origin "refs/tags/$tag:refs/tags/$tag"
git -C "$work" -c advice.detachedHead=false checkout -q "$tag"
commit=$(git -C "$work" rev-parse HEAD)

rm -rf "$vendor/lib"
mkdir -p "$vendor"
cp "$work/LICENSE" "$vendor/LICENSE"
cp -R "$work/lib" "$vendor/lib"
# Node's lint configuration is no built-in.
rm -f "$vendor/lib/eslint.config_partial.mjs"
rm -rf "$vendor/deps"
for dep in $deps; do
    mkdir -p "$vendor/deps/$(dirname "$dep")"
    cp "$work/deps/$dep" "$vendor/deps/$dep"
done

{
    echo "# nodejs/node $tag $commit"
    (cd "$vendor" && find lib deps -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256)
} >"$vendor/lib.sha256"

echo "$0: vendored $(grep -vc '^#' "$vendor/lib.sha256") files of nodejs/node $tag ($commit)" >&2
