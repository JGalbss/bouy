#!/bin/sh
# Reproduces bench/evidence/results/beam-quickjs-<date>-m5pro.json on a macOS host with Docker,
# Node 25, jq, and a scratch install of quickjs-emscripten outside the repository:
#   mkdir -p /tmp/bouy-qjs && cd /tmp/bouy-qjs && npm init -y && npm install quickjs-emscripten@0.32.0
# Usage: sh bench/evidence/beam/run-all.sh [output.json]
set -eu
beam_dir="$(cd "$(dirname "$0")" && pwd -P)"
quickjs_dir="$(cd "$beam_dir/../quickjs" && pwd -P)"
scratch="$(cd "${QJS_DIR:-/tmp/bouy-qjs}" && pwd -P)"
output="${1:-$beam_dir/../results/beam-quickjs-$(date +%F)-m5pro.json}"
erlang_image=erlang:29.1.2
node_image=node:25.9.0
alpine_image=alpine:3.22
raw="$(mktemp -d)"

mark() {
  printf '{"label":"%s","at":"%s","host_loadavg":"%s"}\n' "$1" "$(date -u +%FT%TZ)" \
    "$(sysctl -n vm.loadavg | tr -d '{}' | xargs)" >> "$raw/load.jsonl"
}

tag() {
  jq -c --arg engine "$1" --arg flags "$2" --arg host "$3" '. + {engine: $engine, node_flags: $flags, host: $host}'
}

digest() {
  docker image inspect "$1" --format '{{index .RepoDigests 0}}'
}

docker pull -q "$erlang_image" > /dev/null
docker pull -q "$node_image" > /dev/null
docker pull -q "$alpine_image" > /dev/null
cp "$quickjs_dir/measure-quickjs.mjs" "$quickjs_dir/fib.js" "$scratch/"

jq -n \
  --arg host_model "$(sysctl -n hw.model)" \
  --arg host_cpu "$(sysctl -n machdep.cpu.brand_string)" \
  --arg host_cores "$(sysctl -n hw.ncpu)" \
  --arg host_memory_bytes "$(sysctl -n hw.memsize)" \
  --arg macos "$(sw_vers -productVersion) ($(sw_vers -buildVersion)), Darwin $(uname -r)" \
  --arg node_native "$(node --version)" \
  --arg docker_context "$(docker context show)" \
  --arg docker_server "$(docker version --format '{{.Server.Version}}')" \
  --arg docker_vm "$(docker info --format '{{.OperatingSystem}}; kernel {{.KernelVersion}}; {{.NCPU}} CPUs; {{.MemTotal}} bytes')" \
  --arg erlang_image "$(digest "$erlang_image")" \
  --arg node_image "$(digest "$node_image")" \
  --arg alpine_image "$(digest "$alpine_image")" \
  --arg quickjs_emscripten "$(jq -r .version "$scratch/node_modules/quickjs-emscripten/package.json")" \
  --arg alpine_quickjs "$(docker run --rm "$alpine_image" sh -c 'apk add --no-cache quickjs > /dev/null 2>&1 && apk list --installed 2> /dev/null | grep quickjs')" \
  '$ARGS.named' > "$raw/environment.json"

mark beam-start
docker run --rm -v "$beam_dir:/bench:ro" "$erlang_image" sh /bench/run-beam.sh > "$raw/beam.jsonl"
mark node-docker-start
docker run --rm -v "$beam_dir:/bench:ro" "$node_image" sh /bench/run-node.sh > "$raw/node-docker.jsonl"
mark node-native-start
sh "$beam_dir/run-node.sh" > "$raw/node-native.jsonl"
mark quickjs-native-start
for run in 1 2 3 4 5; do
  node --expose-gc "$scratch/measure-quickjs.mjs" 1000 100 1000000
done > "$raw/quickjs-native.jsonl"
mark quickjs-docker-start
docker run --rm -v "$scratch:/qjs:ro" "$node_image" sh -c \
  'for run in 1 2 3 4 5; do node --expose-gc /qjs/measure-quickjs.mjs 1000 100 1000000; done' \
  > "$raw/quickjs-docker.jsonl"
mark fib-start
for flags in "" "--jitless"; do
  for run in 1 2 3 4 5; do
    # shellcheck disable=SC2086
    node $flags "$quickjs_dir/fib.js" | tag v8 "$flags" macos-native
  done
  docker run --rm -v "$quickjs_dir:/q:ro" "$node_image" sh -c \
    "for run in 1 2 3 4 5; do node $flags /q/fib.js; done" | tag v8 "$flags" docker
done > "$raw/fib-v8.jsonl"
grep '"macos-native"' "$raw/fib-v8.jsonl" > "$raw/fib-native.jsonl"
grep '"docker"' "$raw/fib-v8.jsonl" > "$raw/fib-docker.jsonl"
docker run --rm -v "$quickjs_dir:/q:ro" "$alpine_image" sh -c \
  'apk add --no-cache quickjs > /dev/null 2>&1 && for run in 1 2 3 4 5; do qjs /q/fib.js; done' \
  | tag quickjs-native "" docker > "$raw/fib-qjs.jsonl"
mark end

jq -n \
  --slurpfile environment "$raw/environment.json" \
  --slurpfile load "$raw/load.jsonl" \
  --slurpfile beam "$raw/beam.jsonl" \
  --slurpfile node_docker "$raw/node-docker.jsonl" \
  --slurpfile node_native "$raw/node-native.jsonl" \
  --slurpfile quickjs_native "$raw/quickjs-native.jsonl" \
  --slurpfile quickjs_docker "$raw/quickjs-docker.jsonl" \
  --slurpfile fib_native "$raw/fib-native.jsonl" \
  --slurpfile fib_docker "$raw/fib-docker.jsonl" \
  --slurpfile fib_qjs "$raw/fib-qjs.jsonl" \
  -f "$beam_dir/summarize.jq" > "$output"
"$beam_dir/../../node_modules/.bin/oxfmt" --write "$output" > /dev/null
echo "$output"
