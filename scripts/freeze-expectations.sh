#!/bin/sh
# Freezes the Node oracle for a directory of test programs. For each `<name>.ts`, it runs
# `node <name>.ts`, writes the stdout to `<name>.stdout`, and writes the exit status to
# `<name>.status` when the status is not 0. The tests compare `buoy run` with these files,
# so this script is the only test step that runs node.
#
# The script refuses a node other than the release in `.node-version`. It runs each program
# twice, in the environment of `buoy_env` in crates/buoy-suites/src/lib.rs, and it
# exits when the two runs differ, so a program that depends on time or order cannot enter
# a corpus.
#
# The programs of tests/equivalence and tests/migration call model APIs. For those
# directories, the script starts the fake server of runtime/test/library/buoy_fake_openai.erl and
# points the programs at it with OPENAI_BASE_URL, OPENAI_API_KEY, ANTHROPIC_BASE_URL, and
# ANTHROPIC_API_KEY, as the Rust tests do for Buoy. A `<name>-fixture.ts` file is a file
# that a program starts, so it gets no output. For tests/migration, it runs
# before/src/main.ts, as the README of the fixture describes, and writes
# before/expected.stdout.
#
# tests/npm, tests/packages, and tests/ecosystem hold one directory for each case or package.
# Their programs are the files named main.mjs, main.cjs, main-<variant>.mjs, exports.mjs, and
# exports.cjs outside node_modules, and the output of each is `<program>.stdout`, such as
# `exports.cjs.stdout`, because two programs of a directory share a stem. One case or
# package directory, such as tests/packages/zod@4, freezes only its programs.
#
# The programs of tests/reference run under `buoy run --semantics reference`. Their actor
# programs import "buoy", which the script points at the Node shim in tests/reference/shim.
# A program that names Temporal runs with the polyfill of runtime/vendor/temporal-polyfill.
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
shim=
trap '[ -z "$server" ] || kill "$server" 2>/dev/null; [ -z "$shim" ] || rm -rf "$shim"; rm -rf "$work"' EXIT
server_env=

case "${1%/}" in
*equivalence/* | *migration)
    erlc -o "$work" "$root/runtime/test/library/buoy_fake_openai.erl"
    # The server halts when this shell ends, so an interrupted run leaves no server behind.
    erl -noshell -pa "$work" -eval 'buoy_fake_openai:main()' -extra "$$" >"$work/port" &
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
*reference)
    # The actor programs import "buoy"; Node reads the shim of tests/reference/shim.
    shim="${1%/}/node_modules"
    mkdir -p "$shim"
    ln -sfn ../shim/buoy "$shim/buoy"
    ;;
esac

# Node 25.9 has no Temporal. A program that names it runs with the polyfill that Buoy
# compiles into its runtime, so Node checks how Buoy runs that code. The polyfill installs
# nothing when Node has Temporal.
temporal="$root/runtime/vendor/temporal-polyfill/global.js"

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
*package-suites)
    # Each test file of lookup.json runs three times from its checkout, six files at once,
    # with a deadline of 60 s for each run. A test file whose runs differ is `flaky`, and
    # the tier leaves it out. The output of a test runner holds durations, so node.txt keeps
    # only the outcome.
    checkouts="${XDG_CACHE_HOME:-$HOME/.cache}/buoy/package-suites"
    jq -r '.packages[] | .name as $name | .runs[]? | "\($name)\t\(.file)\t\(.argv | @sh)"' \
        "${1%/}/lookup.json" >"$work/runs"
    cat >"$work/one.sh" <<'EOF'
line=$(sed -n "$1p" "$work/runs")
name=$(printf '%s' "$line" | cut -f1)
file=$(printf '%s' "$line" | cut -f2)
argv=$(printf '%s' "$line" | cut -f3)
outcomes=
for run in 1 2 3; do
    temporary=$(mktemp -d "$work/tmp.XXXXXX")
    status=0
    (cd "$checkouts/$name" && eval "set -- $argv" &&
        env -i PATH="$PATH" HOME="$HOME" TZ=Etc/UTC LANG=C.UTF-8 NO_COLOR=1 CI=1 TMPDIR="$temporary" \
            perl -e '
                my $pid = fork;
                if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127 }
                $SIG{ALRM} = sub { kill "KILL", -$pid; exit 142 };
                alarm 60;
                waitpid($pid, 0);
                exit($? >> 8);
            ' node "$@" >/dev/null 2>&1) || status=$?
    rm -rf "$temporary"
    case $status in
    0) outcomes="$outcomes pass" ;;
    142) outcomes="$outcomes timeout" ;;
    *) outcomes="$outcomes fail" ;;
    esac
done
set -- $outcomes
outcome=$1
[ "$1" = "$2" ] && [ "$2" = "$3" ] || outcome=flaky
printf '%s/%s %s\n' "$name" "$file" "$outcome"
EOF
    export work checkouts
    count=$(wc -l <"$work/runs")
    seq 1 "$count" | xargs -P 6 -n 1 sh "$work/one.sh" >"$work/node"
    {
        echo "# Generated by scripts/freeze-expectations.sh: the outcome of three Node runs of each test file."
        LC_ALL=C sort "$work/node"
    } >"${1%/}/node.txt"
    ;;
*npm | *packages | *ecosystem | */npm/* | */packages/* | */ecosystem/*)
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
        preload=
        if grep -q Temporal "$program"; then
            preload="--import=$temporal"
        fi
        freeze "${program%.ts}" ${preload:+"$preload"} "$program"
    done
    ;;
esac
