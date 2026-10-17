#!/bin/sh
# Runs test262 files or directories on the reference engine (`--semantics reference`): the
# quick loop of engine work. It fetches tc39/test262 at the pinned commit into
# ~/.cache/bouy/test262 on first use, builds the CLI, and runs the dev runner,
# crates/bouy-cli/src/bin/test262-dev.rs, which compiles each test and runs up to 8000
# tests in one VM. The runner prints each failure with its first error line, then a table of
# results per directory.
#
# Usage: scripts/test262-dev.sh [--jobs N] [--timeout-ms N] [--failures FILE] <path>...
# Paths are relative to the test262 checkout, such as test/built-ins/Array/isArray.
# BOUY_TEST262 names another checkout.

set -eu

# The commit that the test harness of main pins (tests/test262/config.json).
commit=d53ebc8b1931d9f1541e43d59650776e4b766248
dir=${BOUY_TEST262:-${XDG_CACHE_HOME:-$HOME/.cache}/bouy/test262}

if [ "$(cat "$dir/.bouy-commit" 2>/dev/null)" != "$commit" ]; then
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    echo "test262-dev: fetching tc39/test262 at $commit" >&2
    curl -fsSL "https://codeload.github.com/tc39/test262/tar.gz/$commit" | tar -xzf - -C "$work"
    rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    mv "$work/test262-$commit" "$dir"
    echo "$commit" >"$dir/.bouy-commit"
fi

root=$(cd "$(dirname "$0")/.." && pwd)
PATH="$HOME/.cargo/bin:$PATH"
cargo build --quiet --manifest-path "$root/Cargo.toml" -p bouy-cli
target=$(cargo metadata --format-version 1 --no-deps --manifest-path "$root/Cargo.toml" |
    sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')
exec "$target/debug/test262-dev" --test262 "$dir" "$@"
