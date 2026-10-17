#!/bin/sh
# Freezes the Node oracle for a directory of test programs. For each `<name>.ts`, it runs
# `node <name>.ts`, writes the stdout to `<name>.stdout`, and writes the exit status to
# `<name>.status` when the status is not 0. The tests compare `bouy run` with these files,
# so this script is the only place that runs node.
#
# The programs of tests/equivalence/ai call an OpenAI API. For that directory, the script
# starts the fake OpenAI server of runtime/test/bouy_fake_openai.erl and points the
# programs at it with OPENAI_BASE_URL and OPENAI_API_KEY, as crates/bouy-cli/tests/ai.rs
# does for Bouy.
#
# The programs of tests/reference run under `bouy run --semantics reference`. Their actor
# programs import "bouy", which the script points at the Node shim in tests/reference/shim.
#
# Usage: scripts/freeze-expectations.sh tests/conformance

set -eu

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <directory>" >&2
    exit 2
fi

case "${1%/}" in
*equivalence/ai)
    work=$(mktemp -d)
    erlc -o "$work" "$(dirname "$0")/../runtime/test/bouy_fake_openai.erl"
    # The server halts when this shell ends, so an interrupted run leaves no server behind.
    erl -noshell -pa "$work" -eval 'bouy_fake_openai:main()' -extra "$$" >"$work/port" &
    server=$!
    trap 'kill "$server" 2>/dev/null; rm -rf "$work"' EXIT
    tries=0
    until grep -q '^[0-9][0-9]*$' "$work/port" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 100 ]; then
            echo "$0: the fake OpenAI server did not start" >&2
            exit 1
        fi
        sleep 0.1
    done
    OPENAI_BASE_URL="http://127.0.0.1:$(head -n 1 "$work/port")/v1"
    OPENAI_API_KEY=sk-fake-key
    export OPENAI_BASE_URL OPENAI_API_KEY
    ;;
*reference)
    # The actor programs import "bouy"; Node reads the shim of tests/reference/shim.
    mkdir -p "$1/node_modules"
    ln -sfn ../shim/bouy "$1/node_modules/bouy"
    trap 'rm -rf "${1%/}/node_modules"' EXIT
    ;;
esac

for program in "$1"/*.ts; do
    [ -f "$program" ] || continue
    name=${program%.ts}
    status=0
    node "$program" >"$name.stdout" 2>/dev/null || status=$?
    if [ "$status" -eq 0 ]; then
        rm -f "$name.status"
    else
        echo "$status" >"$name.status"
        echo "$program: node exited with status $status" >&2
    fi
done
