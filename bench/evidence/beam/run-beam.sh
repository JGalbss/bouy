#!/bin/sh
# Runs inside the official Erlang image and prints one JSON line per run.
#   docker run --rm -v "$PWD/bench/evidence/beam:/bench:ro" erlang:29.1.2 sh /bench/run-beam.sh
# Each run starts a fresh VM. "+S 1:1" pins the VM to one scheduler thread.
set -eu
runs="${RUNS:-5}"
mkdir -p /tmp/ebin
erlc -o /tmp/ebin /bench/actor_bench.erl
for schedulers in default one; do
  flags=""
  if [ "$schedulers" = one ]; then flags="+S 1:1"; fi
  for run in $(seq "$runs"); do
    for benchmark in "spawn 1000000" "spawn-hibernate 1000000" "round-trip 1000000 100000" \
      "gen-server-call 1000000 100000" "ring 10000 100"; do
      # shellcheck disable=SC2086
      erl -noshell +P 2097152 $flags -pa /tmp/ebin -run actor_bench main $benchmark
    done
  done
done
