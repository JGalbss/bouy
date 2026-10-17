#!/bin/sh
# Runs a reference-semantics spike benchmark, alternating BEAM and Node runs.
# Usage: bench/reference/run.sh heap [runs]
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
suite=$1
runs=${2:-3}
ebin="$root/runtime/_build/default/lib/bouy/ebin"
out=$(mktemp -d)
(cd "$root/runtime" && rebar3 compile >/dev/null)
erlc -o "$out" "$here/${suite}_bench.erl"
i=1
while [ "$i" -le "$runs" ]; do
  echo "== run $i: BEAM (OTP $(erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().'))"
  erl -noshell -pa "$out" -pa "$ebin" -eval "${suite}_bench:main()" -s init stop
  echo "== run $i: Node $(node --version)"
  node --expose-gc "$here/${suite}_bench.mjs"
  i=$((i + 1))
done
rm -rf "$out"
