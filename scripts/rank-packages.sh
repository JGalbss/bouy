#!/bin/sh
# Writes tests/packages/ranking.json: the npm packages of the ecosystem tier of
# docs/design/testing.md section 5.8, ranked by weekly downloads.
#
# Sources, each a public API:
# - ecosyste.ms: the candidates, the npm packages with the most downloads in the last month.
# - the npm downloads API: the count of the last week of each candidate, which sets the rank.
# - the npm versions API: the count of the last week of each version, which picks the majors.
# - the npm registry: the metadata of the latest version, which classifies the package.
#
# The file keeps the top 500 and every package of the AI tier. For each one it records:
# - `kind`: `platform-binary` when the metadata names `os` or `cpu`, `types-only` when the
#   entry points name only type declarations, and `program` otherwise. Only a `program`
#   gets a directory in tests/packages.
# - `format`: `esm` when every entry point is an ES module, `cjs` when none is, and `dual`.
# - `versions`: each major version with at least 20% of the weekly downloads, at most three,
#   and the major of the latest version. A major of 0 splits by its minor, as semver does.
#   The version of a major is its highest release, or the latest version for its major.
#
# The AI tier is the list below: the LLM SDKs and agent frameworks, then the validation,
# HTTP, authentication, and utility packages that they load. On 2026-10-16 each package of
# the second group was a dependency of a package of the first group at its latest version.
# Review the list each quarter, when this script runs again.
#
# Usage: scripts/rank-packages.sh. It needs curl and jq, and it takes a few minutes.

set -eu

ai_tier='
ai
@ai-sdk/openai
@ai-sdk/anthropic
@ai-sdk/google
@ai-sdk/gateway
@ai-sdk/provider
@ai-sdk/provider-utils
openai
@anthropic-ai/sdk
@google/genai
@mistralai/mistralai
@modelcontextprotocol/sdk
@langchain/core
@langchain/openai
@langchain/anthropic
@langchain/langgraph
langchain
@openai/agents
@mastra/core
effect
zod
zod-to-json-schema
ajv
ajv-formats
@standard-schema/spec
@cfworker/json-schema
json-schema-to-ts
hono
@hono/node-server
express
body-parser
cors
ws
undici
eventsource
eventsource-parser
raw-body
content-type
express-rate-limit
jose
pkce-challenge
google-auth-library
standardwebhooks
p-retry
p-queue
js-tiktoken
langsmith
mustache
cross-spawn
debug
@opentelemetry/api
protobufjs
dotenv
lru-cache
execa
'

# The candidates: ecosyste.ms pages of 100 packages each.
pages=10
# The packages that the file keeps, apart from the AI tier.
top=500
# The share of the weekly downloads that a major version needs.
share=0.2
# The parallel requests. The npm APIs answer HTTP 429 to more.
jobs=2

root=$(cd "$(dirname "$0")/.." && pwd)
# RANK_WORK keeps the responses between runs, so a rerun fetches only what it lacks.
if [ -n "${RANK_WORK:-}" ]; then
    work=$RANK_WORK
else
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
fi
mkdir -p "$work/weekly" "$work/latest" "$work/versions"

# Reads lines of `<url> <file>` on stdin and fetches each URL into its file, unless the file
# exists. curl waits as a 429 answer asks before each retry.
fetch_all() {
    xargs -P "$jobs" -n 2 sh -c \
        '[ -s "$1" ] || curl -fsS --retry 10 --retry-all-errors --retry-max-time 600 -o "$1" "$0"'
}

# The name of a package as a file name and as a path segment of the registry.
file_of() { printf '%s' "$1" | sed 's#/#+#'; }
path_of() { printf '%s' "$1" | sed 's#/#%2F#'; }

page=1
while [ "$page" -le "$pages" ]; do
    echo "https://packages.ecosyste.ms/api/v1/registries/npmjs.org/packages?sort=downloads&order=desc&per_page=100&page=$page $work/candidates-$page.json"
    page=$((page + 1))
done | fetch_all
{
    jq -r '.[].name' "$work"/candidates-*.json
    printf '%s' "$ai_tier" | grep .
} | sort -u >"$work/names"

# The weekly counts. The bulk form of the API takes up to 128 unscoped names.
grep -v '^@' "$work/names" | split -l 128 - "$work/bulk-"
for bulk in "$work"/bulk-*; do
    echo "https://api.npmjs.org/downloads/point/last-week/$(paste -sd, "$bulk") $work/weekly/$(basename "$bulk").json"
done | fetch_all
grep '^@' "$work/names" | while read -r name; do
    echo "https://api.npmjs.org/downloads/point/last-week/$name $work/weekly/$(file_of "$name").json"
done | fetch_all
jq -s '
    map(if has("downloads") then [.] else [.[] | select(. != null)] end)
    | add
    | map({key: .package, value: {weekly: .downloads, start, end}})
    | from_entries' "$work"/weekly/*.json >"$work/weekly.json"

# The ranked packages that the file keeps.
printf '%s' "$ai_tier" | grep . | jq -R . | jq -s . >"$work/ai.json"
jq -r --argjson top "$top" --slurpfile ai "$work/ai.json" '
    to_entries
    | sort_by(-.value.weekly, .key)
    | to_entries
    | map(select(.key < $top or (.value.key | IN($ai[0][])))) | .[].value.key' \
    "$work/weekly.json" >"$work/kept"

while read -r name; do
    echo "https://registry.npmjs.org/$(path_of "$name")/latest $work/latest/$(file_of "$name").json"
    echo "https://api.npmjs.org/versions/$(path_of "$name")/last-week $work/versions/$(file_of "$name").json"
done <"$work/kept" | fetch_all

jq -s '
    map({key: .name, value: {
        version,
        platform: ((.os // []) + (.cpu // []) | length > 0),
        type: (.type // "commonjs"),
        main: (.main // null),
        module: (.module // null),
        types: (.types // .typings // null),
        exports: (.exports // null)
    }}) | from_entries' "$work"/latest/*.json >"$work/latest.json"
jq -s 'map({key: .package, value: .downloads}) | from_entries' "$work"/versions/*.json \
    >"$work/versions.json"

jq --argjson share "$share" --slurpfile ai "$work/ai.json" \
    --slurpfile latest "$work/latest.json" --slurpfile versions "$work/versions.json" '
    # The major of a version: its major number, or 0.<minor> for a major of 0.
    def major: split("-")[0] | split(".") | if .[0] == "0" then "0.\(.[1])" else .[0] end;
    def release: test("^[0-9]+\\.[0-9]+\\.[0-9]+$");
    def numbers: split("-")[0] | split(".") | map(tonumber);
    # The (condition path, target) pairs of an exports field.
    def targets:
        if type == "string" then [{path: [], target: .}]
        else [paths(type == "string") as $path | {path: $path, target: getpath($path)}] end;
    def declaration: test("\\.d\\.[cm]?ts$");
    def kind:
        if .platform then "platform-binary"
        else
            ([.main, .module] + (if .exports == null then [] else (.exports | targets | map(.target)) end)
                | map(select(. != null and . != "" and (declaration | not)))) as $code
            | if ($code | length) == 0 and .types != null and (.exports != null or .main == "")
              then "types-only" else "program" end
        end;
    def format:
        (if .exports == null then [] else (.exports | targets) end) as $targets
        | ($targets | map(select(.target | declaration | not))) as $code
        | (($code | any(.path | index("require") != null) or any(.target | test("\\.cjs$")))
            or (.main // "" | test("\\.cjs$"))) as $require
        | (($code | any(.path | index("import") != null) or any(.target | test("\\.mjs$")))
            or .module != null) as $import
        | if .type == "module" then (if $require then "dual" else "esm" end)
          else (if $import then "dual" else "cjs" end) end;
    def chosen($latest):
        (to_entries | map(.value) | add) as $total
        | to_entries
        | group_by(.key | major)
        | map({
            major: (.[0].key | major),
            share: ((map(.value) | add) / (if $total > 0 then $total else 1 end)),
            version: (if (.[0].key | major) == ($latest | major) then $latest
                      else (map(select(.key | release)) | sort_by(.key | numbers) | last | .key)
                      end)
          })
        | map(select(.version != null)) as $groups
        | ($groups | map(select(.share >= $share)) | sort_by(-.share) | .[0:3])
            + [{major: ($latest | major), version: $latest,
                share: ($groups | map(select(.major == ($latest | major))) | .[0].share // 0)}]
        | unique_by(.major)
        | sort_by(.version | numbers)
        | map({major, version, share: ((.share * 1000 | round) / 1000)});
    . as $weekly
    | to_entries
    | sort_by(-.value.weekly, .key)
    | to_entries
    | map(.value.key as $name | $latest[0][$name] as $meta | select($meta != null) | {
        name: $name,
        rank: (.key + 1),
        weekly: .value.value.weekly,
        ai: ($name | IN($ai[0][])),
        kind: ($meta | kind),
        format: ($meta | format),
        latest: $meta.version,
        versions: ($versions[0][$name] // {} | chosen($meta.version))
      }) as $packages
    | {
        generated_by: "scripts/rank-packages.sh",
        week: ($weekly | [.[]] | {"start": (map(.start) | min), "end": (map(.end) | max)}),
        sources: [
          "https://packages.ecosyste.ms/api/v1/registries/npmjs.org/packages?sort=downloads",
          "https://api.npmjs.org/downloads/point/last-week/<name>",
          "https://api.npmjs.org/versions/<name>/last-week",
          "https://registry.npmjs.org/<name>/latest"
        ],
        ai_tier: ($packages | map(select(.ai)) | length),
        packages: $packages
      }' "$work/weekly.json" >"$work/ranking.json"

missing=$(jq -r --slurpfile ai "$work/ai.json" '$ai[0] - (.packages | map(.name)) | .[]' "$work/ranking.json")
if [ -n "$missing" ]; then
    echo "$0: the registry has no metadata for these packages of the AI tier: $missing" >&2
    exit 1
fi
mkdir -p "$root/tests/packages"
mv "$work/ranking.json" "$root/tests/packages/ranking.json"
echo "wrote tests/packages/ranking.json: $(jq '.packages | length' "$root/tests/packages/ranking.json") packages, $(jq '.ai_tier' "$root/tests/packages/ranking.json") in the AI tier"
