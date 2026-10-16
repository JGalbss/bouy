#!/bin/sh
# Runs the Node in-isolate equivalents of actor_bench.erl and prints one JSON line per run.
#   docker run --rm -v "$PWD/bench/evidence/beam:/bench:ro" node:25.9.0 sh /bench/run-node.sh
#   sh bench/evidence/beam/run-node.sh
set -eu
dir="$(dirname "$0")"
runs="${RUNS:-5}"
spawn_count="${SPAWN_COUNT:-1000000}"
round_trips="${ROUND_TRIPS:-1000000}"
ring_laps="${RING_LAPS:-100}"
for run in $(seq "$runs"); do
  for benchmark in "spawn-async $spawn_count" "spawn-async-als $spawn_count" \
    "spawn-object $spawn_count" "round-trip $round_trips 100000" "ring 10000 $ring_laps"; do
    # shellcheck disable=SC2086
    node --expose-gc "$dir/node-actors.ts" $benchmark
  done
done
