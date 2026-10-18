#!/bin/sh
# Runs the programs of bench/reference/programs under Node, `buoy run` (value semantics),
# and `buoy run --semantics reference`, in turns, so that a change in the load of the
# machine reaches all three. Each line is the load average and the JSON line of one run.
# A program that value semantics rejects or cannot finish skips that runtime. The memory
# and collector programs, realm-memory and actor-gc, run once under reference semantics.
# Usage: bench/reference/programs.sh [runs] [buoy]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
runs=${1:-3}
buoy=${2:-$root/target/debug/buoy}
programs="$here/programs"
mkdir -p "$programs/node_modules"
ln -sfn "$root/tests/reference/shim/buoy" "$programs/node_modules/buoy"
trap 'rm -rf "$programs/node_modules"' EXIT
load() { sysctl -n vm.loadavg | tr -d '{}' | awk '{print $1, $2, $3}'; }
measure() {
  label=$1
  shift
  out=$("$@" 2>&1 | tail -n 1)
  echo "$label load $(load): $out"
}
value_runs() {
  case "$1" in
  objects-from | methods | closures-value) return 0 ;;
  *) return 1 ;;
  esac
}
for program in objects objects-from methods classes closures closures-value; do
  i=1
  while [ "$i" -le "$runs" ]; do
    measure "node      $program" node "$programs/$program.ts"
    if value_runs "$program"; then
      measure "value     $program" "$buoy" run "$programs/$program.ts"
    fi
    measure "reference $program" "$buoy" run --semantics reference "$programs/$program.ts"
    i=$((i + 1))
  done
done
for program in realm-memory actor-gc; do
  echo "reference $program load $(load):"
  "$buoy" run --semantics reference "$programs/$program.ts" 2>&1
done
