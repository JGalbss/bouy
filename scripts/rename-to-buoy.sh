#!/bin/sh
# Renames the project from the misspelled "Bouy" to "Buoy" in the checkout of the current
# branch. It moves each tracked path whose name contains bouy, Bouy, or BOUY with `git mv`,
# points the tracked symlinks at the new paths, and replaces the three spellings in each
# tracked text file. Then cargo rewrites the Cargo.lock files for the renamed crates.
#
# It skips the vendored upstream files (tests/node/test and runtime/vendor), because the rule
# checks hash them against upstream, and it skips binary files and this script. Untracked
# files, such as node_modules, target, and _build, stay as they are, except the ignored .bouy
# build directories, which it deletes because the new name is .buoy. The links to
# github.com/JGalbss/bouy stay until the GitHub repository has the new name.
#
# A second run changes nothing, so the script can run again on any branch.
#
# Usage: scripts/rename-to-buoy.sh

set -eu

root=$(git rev-parse --show-toplevel)
cd "$root"

# The tracked files that the rename may change. Cargo writes Cargo.lock, so the text pass
# leaves it alone.
set -- . ':!tests/node/test' ':!tests/node/suite' ':!runtime/vendor' \
    ':!scripts/rename-to-buoy.sh' ':!*Cargo.lock'

respell() {
    sed -e 's/bouy/buoy/g' -e 's/Bouy/Buoy/g' -e 's/BOUY/BUOY/g'
}

git ls-files --others --ignored --exclude-standard --directory |
    grep -E '(^|/)\.bouy/$' |
    while IFS= read -r build; do
        rm -rf "$build"
    done

# An untracked file under an old path would keep the old directory, and cargo would read an
# empty crates/bouy-* as a workspace member.
untracked=$(git ls-files --others --directory | grep -E 'bouy|Bouy|BOUY' || true)
if [ -n "$untracked" ]; then
    echo "$0: move or delete these untracked paths, then run again:" >&2
    printf '%s\n' "$untracked" >&2
    exit 1
fi

git ls-files -- "$@" | grep -E 'bouy|Bouy|BOUY' | while IFS= read -r path; do
    new=$(printf '%s\n' "$path" | respell)
    mkdir -p "$(dirname "$new")"
    git mv "$path" "$new"
    rmdir -p "$(dirname "$path")" 2>/dev/null || true
done

git ls-files -s -- "$@" | awk '$1 == "120000" { print $4 }' | while IFS= read -r link; do
    target=$(readlink "$link")
    new=$(printf '%s\n' "$target" | respell)
    [ "$new" = "$target" ] && continue
    ln -sfn "$new" "$link"
    git add "$link"
done

migration=$(git grep -lI -e bouy -e Bouy -e BOUY -- tests/migration/before || true)

git grep -lzI -e bouy -e Bouy -e BOUY -- "$@" |
    xargs -0 perl -pi -e 's/Bouy/Buoy/g; s/BOUY/BUOY/g; s{(?<!JGalbss/)bouy}{buoy}g'

# The rule check of crates/buoy-suites/tests/rules.rs hashes the migration fixture, so a
# renamed fixture file needs a new hash. This is the command of that rule.
if [ -n "$migration" ]; then
    (cd tests/migration && find before -type f ! -name .DS_Store ! -path '*/.buoy/*' |
        LC_ALL=C sort | xargs shasum -a 256 > before.sha256)
fi

if command -v cargo >/dev/null 2>&1; then
    cargo metadata --format-version 1 >/dev/null
    cargo metadata --format-version 1 --manifest-path bench/speed/native/Cargo.toml >/dev/null
else
    echo "$0: cargo is not on PATH; run cargo metadata to rewrite the Cargo.lock files" >&2
fi

git ls-files | grep -E 'bouy|Bouy|BOUY' | grep -v -E '^(tests/node/test|runtime/vendor)/' |
    sed "s|^|$0: a tracked path still has the old name: |" >&2 || true
