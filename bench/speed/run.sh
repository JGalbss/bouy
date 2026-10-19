#!/bin/sh
# Runs the speed-ceiling spike of docs/research/speed-ceiling.md and appends one JSON line
# per measurement to a results file. Each line names the mode, the runtime, the round, and
# the 1-minute load average before the run, and holds the JSON line of the program.
#
# Modes:
#   single     each kernel on every runtime, in turns, ROUNDS times
#   multicore  N copies of Richards and of NBody at once, N = the core count
#   preempt    the preemption proof on a VM with one scheduler
#   gc         each kernel of KERNELS on BUOY_ENGINE with gc_share.erl, which records
#              the time of BEAM's garbage collections in the run
#   jit        each kernel of the native tier on BUOY_JIT_CLI, with the native tier and
#              without it (BUOY_JIT=0), and on the baselines of SPEED_JS, ROUNDS times
#
# Environment:
#   SPEED_JS      the JavaScript baselines as name=path pairs, such as
#                 "bun=$(command -v bun) node=/opt/homebrew/bin/node". The product never
#                 runs on them (AGENTS.md); they are the baselines of goal.md requirement 11.
#   BUOY_ENGINE   optional: the buoy CLI built from the engine branch. Its programs have no
#                 process.argv yet, so the script writes a copy of each kernel with smaller
#                 sizes, and the report scales the time to the same unit of work.
#   ENGINE_LABEL  the runtime name of BUOY_ENGINE in the results, "engine" by default, so
#                 two builds can be compared in one file
#   KERNELS       the kernels of the single mode, all eight by default
#   BUOY_JIT_CLI  the buoy CLI that the jit mode measures. The Erlang tier runs smaller
#                 sizes, as BUOY_ENGINE does, and the report scales its time.
#   ROUNDS        rounds of the single, gc, and jit modes, 5 by default
#   GC_RUNS       the timed runs of each engine kernel in the gc mode, 3 by default
#   ERL, ERLC     the OTP tools, erl and erlc on PATH by default
#
# Every VM gets +hmax of 4 GiB, so a runaway process dies and not the machine, and the
# script starts one VM at a time.
#
# Usage: bench/speed/run.sh single|multicore|preempt|gc|jit <results.jsonl>

set -eu

mode=${1:?usage: run.sh single|multicore|preempt|gc|jit <results.jsonl>}
out=${2:?usage: run.sh single|multicore|preempt|gc|jit <results.jsonl>}
here=$(cd "$(dirname "$0")" && pwd)
build=${TMPDIR:-/tmp}/buoy-speed-build
rounds=${ROUNDS:-5}
erl=${ERL:-erl}
erlc=${ERLC:-erlc}
cores=$(getconf _NPROCESSORS_ONLN)

mkdir -p "$build/ebin" "$build/engine"
"$erlc" -o "$build/ebin" "$here"/erlang/*.erl
cargo build --quiet --release --manifest-path "$here/native/Cargo.toml" --target-dir "$build/target"
for library in "$build"/target/release/libbuoy_speed_native.dylib "$build"/target/release/libbuoy_speed_native.so; do
    if [ -f "$library" ]; then cp "$library" "$build/speed_native.so"; fi
done
export SPEED_NATIVE_LIB="$build/speed_native"
export BUOY_MAX_MEMORY=4G

load() { uptime | sed 's/.*load averages*: *//; s/,* .*//'; }

# record <runtime> <round> <command...>: runs the command and appends its last line.
record() {
    runtime=$1
    round=$2
    shift 2
    before=$(load)
    line=$("$@" 2>&1 | tail -n 1)
    case "$line" in
    "{"*) ;;
    *) line="{\"error\":\"$(printf '%s' "$line" | tr -d '"\\')\"}" ;;
    esac
    printf '{"mode":"%s","runtime":"%s","round":%s,"load_1m":%s,"result":%s}\n' \
        "$mode" "$runtime" "$round" "$before" "$line" >>"$out"
    printf '%s %s round %s: %s\n' "$mode" "$runtime" "$round" "$line"
}

# `-run M main` with no arguments would call main/0, so every call passes some.
vm() { "$erl" +hmax 536870912 +hmaxk true -noshell -pa "$build/ebin" "$@"; }

# The engine programs: one warm-up, three timed runs, and a smaller size.
engine_size() {
    case $1 in
    richards) echo 2 ;;
    nbody) echo 20000 ;;
    *) echo 1 ;;
    esac
}

engine_copy() {
    sed -E "s/^bench\(\"$1\", [0-9]+, iteration\);/bench(\"$1\", $(engine_size "$1"), iteration);/; \
        s/const warmup = args\[0\] \?\? 3;/const warmup = args[0] ?? 1;/; \
        s/const runs = args\[1\] \?\? 5;/const runs = args[1] ?? 3;/" \
        "$here/kernels/$1.ts" >"$build/engine/$1.ts"
}

erlang_modules() {
    case $1 in
    richards) echo "richards_heap richards_local" ;;
    deltablue) echo "deltablue_heap" ;;
    nbody) echo "nbody_typed nbody_flat" ;;
    *) echo "$1_typed" ;;
    esac
}

single() {
    for round in $(seq 1 "$rounds"); do
        for kernel in ${KERNELS:-richards deltablue nbody json strings regex mapset closures}; do
            for pair in ${SPEED_JS:-}; do
                record "${pair%%=*}" "$round" "${pair#*=}" "$here/kernels/$kernel.ts"
            done
            for module in $(erlang_modules "$kernel"); do
                record "erlang:$module" "$round" vm -run "$module" main 3 5
            done
            case $kernel in
            richards | deltablue | nbody | json | regex)
                record native "$round" vm -run speed_native main "$kernel" 3 5
                ;;
            esac
            if [ -n "${BUOY_ENGINE:-}" ]; then
                engine_copy "$kernel"
                record "${ENGINE_LABEL:-engine}" "$round" "$BUOY_ENGINE" run --semantics reference "$build/engine/$kernel.ts"
            fi
        done
    done
}

# Each copy runs for a few seconds alone; the sizes differ by runtime for that reason.
multicore() {
    for round in 1 2 3; do
        for pair in ${SPEED_JS:-}; do
            record "${pair%%=*}" "$round" "${pair#*=}" "$here/workers.ts" "$here/kernels/richards.ts" "$cores" 30000
            record "${pair%%=*}" "$round" "${pair#*=}" "$here/workers.ts" "$here/kernels/nbody.ts" "$cores" 20000000
        done
        record erlang:richards_local "$round" vm -run multicore main richards-typed "$cores" 3000
        record native "$round" vm -run multicore main richards-native "$cores" 100000
        record erlang:nbody_flat "$round" vm -run multicore main nbody-typed "$cores" 4000000
        record native "$round" vm -run multicore main nbody-native "$cores" 50000000
    done
}

preempt() {
    for round in 1 2 3; do
        record native "$round" "$erl" +S 1 +hmax 536870912 -noshell -pa "$build/ebin" -run preempt main native-nbody 60000000
        record native "$round" "$erl" +S 1 +hmax 536870912 -noshell -pa "$build/ebin" -run preempt main native-richards 100000
        record erlang:nbody_flat "$round" "$erl" +S 1 +hmax 536870912 -noshell -pa "$build/ebin" -run preempt main erlang-nbody 4000000
        record blocking "$round" "$erl" +S 1 +hmax 536870912 -noshell -pa "$build/ebin" -run preempt main blocking-nbody 30000000
    done
}

# The engine copy of each kernel runs to its end, with one warm-up and GC_RUNS timed runs;
# the record is the last line that gc_share wrote, about every 200 ms.
gc() {
    runs=${GC_RUNS:-3}
    for round in $(seq 1 "$rounds"); do
        for kernel in ${KERNELS:-json strings regex mapset}; do
            engine_copy "$kernel"
            rm -f "$build/gc.json"
            ERL_AFLAGS="-pa $build/ebin -eval gc_share:start()" GC_SHARE_OUT="$build/gc.json" \
                GC_SHARE_KERNEL="$kernel" GC_SHARE_RUNS="$runs" \
                "$BUOY_ENGINE" run --semantics reference "$build/engine/$kernel.ts" 1 "$runs" >/dev/null 2>&1 || true
            record "${ENGINE_LABEL:-engine}" "$round" cat "$build/gc.json"
        done
    done
}

# The native tier runs the kernels at full size; the Erlang tier runs the sizes of
# engine_size with one warm-up and three timed iterations.
jit() {
    for round in $(seq 1 "$rounds"); do
        for kernel in nbody richards deltablue; do
            for pair in ${SPEED_JS:-}; do
                record "${pair%%=*}" "$round" "${pair#*=}" "$here/kernels/$kernel.ts"
            done
            record buoy:jit "$round" "$BUOY_JIT_CLI" run --semantics reference "$here/kernels/$kernel.ts"
            record buoy:erlang "$round" env BUOY_JIT=0 "$BUOY_JIT_CLI" run --semantics reference \
                "$here/kernels/$kernel.ts" 1 3 "$(engine_size "$kernel")"
        done
    done
}

"$mode"
