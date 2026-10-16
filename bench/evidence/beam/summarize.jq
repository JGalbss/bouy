# Builds the results file from the raw JSON lines that run-all.sh records.
# Each summary value is the median, minimum, and maximum across runs of one per-run metric.

def median: sort | if length % 2 == 1 then .[(length - 1) / 2] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def stats(f): [.[] | f] | {median: median, min: min, max: max, runs: length};

def latency: {
  untimed_mean_ns: stats(.untimed_mean_ns),
  round_trips_per_s: stats(.round_trips_per_s),
  p50_ns: stats(.latency_ns.p50),
  p99_ns: stats(.latency_ns.p99),
  p999_ns: stats(.latency_ns.p999),
  timer_only_mean_ns: stats(.timer_only_ns.mean)
};

def ring: {setup_ns: stats(.setup_ns), ns_per_hop: stats(.ns_per_hop), hops_per_s: stats(.hops_per_s)};

def beam_summary:
  group_by([.mode, .vm.schedulers_online])
  | map({
      key: "\(.[0].mode) schedulers_online=\(.[0].vm.schedulers_online)",
      value: (
        if (.[0].mode | startswith("spawn")) then {
          spawn_ns_per_process: stats(.spawn_ns_per_process),
          processes_bytes_per_process: stats(.processes_bytes_per_process),
          processes_used_bytes_per_process: stats(.processes_used_bytes_per_process),
          process_info_bytes_per_process: stats(.process_info_bytes_per_process),
          total_bytes_per_process: stats(.total_bytes_per_process)
        }
        elif .[0].mode == "ring" then ring
        else latency end)
    })
  | from_entries;

def node_summary:
  group_by(.mode)
  | map({
      key: .[0].mode,
      value: (
        if .[0].mode == "round-trip" then latency
        elif .[0].mode == "ring" then ring
        else {
          spawn_ns_per_actor: stats(.spawn_ns_per_actor),
          heap_used_bytes_per_actor: stats(.heap_used_bytes_per_actor),
          rss_bytes_per_actor: stats(.rss_bytes_per_actor)
        } end)
    })
  | from_entries;

def batch(used): {
  create_us_per_item: stats(.create_us_per_item),
  quickjs_used_bytes: stats(used),
  rss_bytes_per_item: stats(.rss_bytes_per_item),
  wasm_growth_bytes_per_item: stats(.wasm_growth_bytes_per_item),
  host_heap_bytes_per_item: stats(.host_heap_bytes_per_item)
};

def quickjs_summary: {
  runtimes: (map(.runtimes) | batch(.quickjs_used_bytes_per_runtime_mean)),
  contexts_in_one_runtime: (map(.contexts_in_one_runtime) | batch(.quickjs_used_bytes_per_context)),
  runtime_context_pairs: (map(.runtime_context_pairs) | batch(.quickjs_used_bytes_per_pair_mean)),
  wasm_modules: (map(.wasm_modules) | {
    create_ms_per_module: stats(.create_ms_per_module),
    wasm_memory_bytes_per_module: stats(.wasm_memory_bytes_per_module),
    rss_bytes_per_module: stats(.rss_bytes_per_module),
    host_heap_bytes_per_module: stats(.host_heap_bytes_per_module)
  }),
  round_trip_between_runtimes: (map(.round_trip_between_runtimes) | {
    untimed_mean_ns: stats(.untimed_mean_ns),
    round_trips_per_s: stats(.round_trips_per_s),
    p50_ns: stats(.latency_ns.p50),
    p99_ns: stats(.latency_ns.p99)
  }),
  fib27_warm_ms: stats(.fib_quickjs_wasm.host_timed_warm_ms | median)
};

def fib_summary: {first_ms: stats(.first_ms), warm_ms: stats(.warm_ms | median)};

{
  environment: $environment[0],
  host_load: $load,
  summary: {
    beam_docker: ($beam | beam_summary),
    node_docker: ($node_docker | node_summary),
    node_native: ($node_native | node_summary),
    quickjs_wasm_native: ($quickjs_native | quickjs_summary),
    quickjs_wasm_docker: ($quickjs_docker | quickjs_summary),
    fib27_ms: {
      v8_jit_native: ($fib_native | map(select(.node_flags == "")) | fib_summary),
      v8_jitless_native: ($fib_native | map(select(.node_flags == "--jitless")) | fib_summary),
      v8_jit_docker: ($fib_docker | map(select(.node_flags == "")) | fib_summary),
      v8_jitless_docker: ($fib_docker | map(select(.node_flags == "--jitless")) | fib_summary),
      quickjs_native_alpine_docker: ($fib_qjs | fib_summary),
      quickjs_wasm_native: {warm_ms: ($quickjs_native | stats(.fib_quickjs_wasm.host_timed_warm_ms | median))},
      quickjs_wasm_docker: {warm_ms: ($quickjs_docker | stats(.fib_quickjs_wasm.host_timed_warm_ms | median))}
    }
  },
  raw: {
    beam_docker: $beam,
    node_docker: $node_docker,
    node_native: $node_native,
    quickjs_wasm_native: $quickjs_native,
    quickjs_wasm_docker: $quickjs_docker,
    fib_v8_native: $fib_native,
    fib_v8_docker: $fib_docker,
    fib_quickjs_native_alpine_docker: $fib_qjs
  }
}
