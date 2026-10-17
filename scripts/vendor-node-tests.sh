#!/bin/sh
# Vendors Node's own tests (section 5.7 of docs/design/testing.md). It fetches nodejs/node at
# the tag of `.node-version` and copies `test/common`, `test/fixtures`, `test/parallel`,
# `test/sequential`, and `test/es-module` into tests/node/suite, with Node's LICENSE. It copies
# every file of these directories, so the denominator is in the repository.
#
# It writes tests/node/suite.sha256, one `shasum -a 256` line for each upstream file, and
# records the tag and the commit in tests/node/config.json. The rule check of
# crates/bouy-suites/tests/rules.rs hashes each vendored file against suite.sha256, so a test
# file stays byte-identical. Bouy edits only files of tests/node/suite/common, each with a
# `// Bouy:` comment and a line in tests/node/edited.txt. A new vendor run overwrites those
# edits; the script names the files of edited.txt, and `git diff` shows the edits to apply
# again.
#
# This script runs no node. Then run
# `cargo run --release -p bouy-suites -- node --update` and `pnpm compat`.
#
# Usage: scripts/vendor-node-tests.sh

set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
tag="v$(cat "$root/.node-version")"
node_dir="$root/tests/node"
suite="$node_dir/suite"
directories="common fixtures parallel sequential es-module"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "$0: fetching nodejs/node at $tag" >&2
git -C "$work" init -q
git -C "$work" remote add origin https://github.com/nodejs/node.git
git -C "$work" sparse-checkout set --no-cone /LICENSE /test/common/ /test/fixtures/ \
    /test/parallel/ /test/sequential/ /test/es-module/
git -C "$work" fetch -q --depth 1 --filter=blob:none origin "refs/tags/$tag:refs/tags/$tag"
git -C "$work" -c advice.detachedHead=false checkout -q "$tag"
commit=$(git -C "$work" rev-parse HEAD)

rm -rf "$suite"
mkdir -p "$suite"
cp "$work/LICENSE" "$suite/LICENSE"
for directory in $directories; do
    cp -R "$work/test/$directory" "$suite/$directory"
done

(cd "$suite" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) |
    sed 's|  \./|  |' >"$node_dir/suite.sha256"

# The tag and the commit are the first two keys of config.json; the rest stays as it is.
config="$node_dir/config.json"
sed -e "s|^  \"tag\": \".*\",\$|  \"tag\": \"$tag\",|" \
    -e "s|^  \"commit\": \".*\",\$|  \"commit\": \"$commit\",|" "$config" >"$work/config.json"
cp "$work/config.json" "$config"

echo "$0: vendored $(wc -l <"$node_dir/suite.sha256" | tr -d ' ') files of nodejs/node $tag ($commit)" >&2
edited=$(grep -v '^#' "$node_dir/edited.txt" | grep -v '^$' | cut -d' ' -f1 || true)
if [ -n "$edited" ]; then
    echo "$0: apply the Bouy edits of these files again; git diff shows them:" >&2
    echo "$edited" >&2
fi
