#!/bin/sh
# Freezes the Node oracle for a directory of test programs. For each `<name>.ts`, it runs
# `node <name>.ts`, writes the stdout to `<name>.stdout`, and writes the exit status to
# `<name>.status` when the status is not 0. The tests compare `bouy run` with these files,
# so this script is the only test step that runs node.
#
# The script refuses a node other than the release in `.node-version`. It runs each program
# twice, in the environment of `bouy_env` in crates/bouy-suites/src/lib.rs, and it
# exits when the two runs differ, so a program that depends on time or order cannot enter
# a corpus.
#
# The programs of tests/equivalence and tests/migration call model APIs. For those
# directories, the script starts the fake server of runtime/test/bouy_fake_openai.erl and
# points the programs at it with OPENAI_BASE_URL, OPENAI_API_KEY, ANTHROPIC_BASE_URL, and
# ANTHROPIC_API_KEY, as the Rust tests do for Bouy. A `<name>-fixture.ts` file is a file
# that a program starts, so it gets no output. For tests/migration, it runs
# before/src/main.ts, as the README of the fixture describes, and writes
# before/expected.stdout.
#
# tests/npm and tests/packages hold one directory for each case or package. Their programs
# are the files named main.mjs, main.cjs, main-<variant>.mjs, exports.mjs, and exports.cjs
# outside node_modules, and the output of each is `<program>.stdout`, such as
# `exports.cjs.stdout`, because two programs of a directory share a stem. One case or
# package directory, such as tests/packages/zod@4, freezes only its programs.
#
# Usage: scripts/freeze-expectations.sh tests/conformance

set -eu

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <directory>" >&2
    exit 2
fi

root=$(cd "$(dirname "$0")/.." && pwd)
pinned="v$(cat "$root/.node-version")"
found=$(node --version)
if [ "$found" != "$pinned" ]; then
    echo "$0: node is $found, and .node-version pins $pinned; run the pinned release" >&2
    exit 1
fi

work=$(mktemp -d)
server=
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; rm -rf "$work"' EXIT
server_env=

case "${1%/}" in
*equivalence/* | *migration)
    erlc -o "$work" "$root/runtime/test/bouy_fake_openai.erl"
    # The server halts when this shell ends, so an interrupted run leaves no server behind.
    erl -noshell -pa "$work" -eval 'bouy_fake_openai:main()' -extra "$$" >"$work/port" &
    server=$!
    tries=0
    until grep -q '^[0-9][0-9]*$' "$work/port" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 100 ]; then
            echo "$0: the fake OpenAI server did not start" >&2
            exit 1
        fi
        sleep 0.1
    done
    port=$(head -n 1 "$work/port")
    server_env="OPENAI_BASE_URL=http://127.0.0.1:$port/v1 OPENAI_API_KEY=sk-fake-key"
    server_env="$server_env ANTHROPIC_BASE_URL=http://127.0.0.1:$port ANTHROPIC_API_KEY=sk-fake-key"
    ;;
esac

# Runs node twice on the arguments after <name> and records the agreed output as
# <name>.stdout and <name>.status.
freeze() {
    name=$1
    shift
    for run in 1 2; do
        mkdir "$work/tmp$run"
        status=0
        # $server_env splits into its assignments on purpose.
        env -i PATH="$PATH" HOME="$HOME" TZ=Etc/UTC LANG=C.UTF-8 NO_COLOR=1 CI=1 \
            TMPDIR="$work/tmp$run" $server_env node "$@" >"$work/stdout$run" 2>/dev/null ||
            status=$?
        echo "$status" >"$work/status$run"
        rm -rf "$work/tmp$run"
    done
    if ! cmp -s "$work/stdout1" "$work/stdout2" || ! cmp -s "$work/status1" "$work/status2"; then
        echo "$0: two node runs of $name differ, so the program depends on time or order:" >&2
        diff "$work/stdout1" "$work/stdout2" >&2 || true
        echo "statuses: $(cat "$work/status1") and $(cat "$work/status2")" >&2
        exit 1
    fi
    mv "$work/stdout1" "$name.stdout"
    status=$(cat "$work/status1")
    if [ "$status" -eq 0 ]; then
        rm -f "$name.status"
    else
        echo "$status" >"$name.status"
        echo "$name: node exited with status $status" >&2
    fi
}

case "${1%/}" in
*migration)
    freeze "${1%/}/before/expected" --experimental-transform-types "${1%/}/before/src/main.ts"
    ;;
*npm | *packages | */npm/* | */packages/*)
    # The names of these programs hold no spaces.
    for program in $(find "${1%/}" -name node_modules -prune -o -type f \( -name main.mjs \
        -o -name main.cjs -o -name 'main-*.mjs' -o -name exports.mjs -o -name exports.cjs \) \
        -print | LC_ALL=C sort); do
        freeze "$program" "$program"
    done
    ;;
*)
    for program in "$1"/*.ts; do
        [ -f "$program" ] || continue
        case "$program" in *-fixture.ts) continue ;; esac
        freeze "${program%.ts}" "$program"
    done
    ;;
esac
