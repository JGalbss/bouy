import { readFileSync } from "node:fs";
import { getQuickJS, newQuickJSWASMModule } from "quickjs-emscripten";

const [count = 1000, moduleCount = 100, exchanges = 100000] = process.argv.slice(2).map(Number);
const collect = globalThis.gc;
if (collect === undefined) throw new Error("Run with node --expose-gc.");

const QuickJS = await getQuickJS();
const wasmMemory = QuickJS.getWasmMemory();

const usedBytes = (runtime) =>
  Number(/memory used\s+\d+\s+(\d+)/u.exec(runtime.dumpMemoryUsage())?.[1] ?? Number.NaN);

const createBatch = (create) => {
  collect();
  const before = { wasm: wasmMemory.buffer.byteLength, ...process.memoryUsage() };
  const start = performance.now();
  const created = Array.from({ length: count }, create);
  const elapsed = performance.now() - start;
  collect();
  const after = { wasm: wasmMemory.buffer.byteLength, ...process.memoryUsage() };
  return {
    created,
    timing: {
      count,
      create_us_total: elapsed * 1000,
      create_us_per_item: (elapsed * 1000) / count,
      wasm_memory_before_bytes: before.wasm,
      wasm_memory_after_bytes: after.wasm,
      wasm_growth_bytes_per_item: (after.wasm - before.wasm) / count,
      rss_bytes_per_item: (after.rss - before.rss) / count,
      host_heap_bytes_per_item: (after.heapUsed - before.heapUsed) / count,
    },
  };
};

const runtimes = createBatch(() => QuickJS.newRuntime());
const runtimeUsed = runtimes.created.map(usedBytes);

const shared = QuickJS.newRuntime();
const sharedEmptyUsed = usedBytes(shared);
const contexts = createBatch(() => shared.newContext());
const sharedFullUsed = usedBytes(shared);

const pairs = createBatch(() => QuickJS.newContext());
const pairUsed = pairs.created.map((context) => usedBytes(context.runtime));

collect();
const modulesBefore = process.memoryUsage();
const modulesStart = performance.now();
const modules = await Array.fromAsync({ length: moduleCount }, async () => {
  const module = await newQuickJSWASMModule();
  return { module, context: module.newContext() };
});
const modulesElapsed = performance.now() - modulesStart;
collect();
const modulesAfter = process.memoryUsage();

const fibContext = QuickJS.newContext();
fibContext
  .unwrapResult(fibContext.evalCode(readFileSync(new URL("fib.js", import.meta.url), "utf8")))
  .dispose();
const guestTimed = fibContext
  .getProp(fibContext.global, "fibResult")
  .consume((value) => fibContext.dump(value));
const hostTimed = Array.from({ length: 6 }, () => {
  const start = performance.now();
  fibContext.unwrapResult(fibContext.evalCode("fib(27)")).dispose();
  return performance.now() - start;
});

const client = QuickJS.newContext();
const server = QuickJS.newContext();
client
  .unwrapResult(
    client.evalCode("globalThis.receive = (reply) => reply === 'pong' ? 'ping' : 'stop';"),
  )
  .dispose();
server
  .unwrapResult(
    server.evalCode("globalThis.receive = (request) => request === 'ping' ? 'pong' : 'error';"),
  )
  .dispose();
const receivers = new Map(
  [client, server].map((context) => [context, context.getProp(context.global, "receive")]),
);

const deliver = (context, message) => {
  const argument = context.newString(message);
  const reply = context.unwrapResult(
    context.callFunction(receivers.get(context), context.undefined, argument),
  );
  argument.dispose();
  return reply.consume((value) => context.getString(value));
};

for (let index = 0; index < exchanges / 10; index += 1) deliver(client, deliver(server, "ping"));
const untimedStart = performance.now();
for (let index = 0; index < exchanges; index += 1) deliver(client, deliver(server, "ping"));
const untimedMs = performance.now() - untimedStart;
const latencies = Float64Array.from({ length: exchanges }, () => {
  const start = performance.now();
  deliver(client, deliver(server, "ping"));
  return performance.now() - start;
}).toSorted();

const mean = (values) => values.reduce((sum, value) => sum + value, 0) / values.length;
const percentileNs = (fraction) =>
  Math.round(latencies[Math.max(0, Math.ceil(fraction * exchanges) - 1)] * 1e6);

console.log(
  JSON.stringify({
    node: process.version,
    v8: process.versions.v8,
    platform: process.platform,
    arch: process.arch,
    runtimes: { ...runtimes.timing, quickjs_used_bytes_per_runtime_mean: mean(runtimeUsed) },
    contexts_in_one_runtime: {
      ...contexts.timing,
      quickjs_used_bytes_empty_runtime: sharedEmptyUsed,
      quickjs_used_bytes_per_context: (sharedFullUsed - sharedEmptyUsed) / count,
    },
    runtime_context_pairs: { ...pairs.timing, quickjs_used_bytes_per_pair_mean: mean(pairUsed) },
    wasm_modules: {
      count: modules.length,
      create_ms_per_module: modulesElapsed / moduleCount,
      wasm_memory_bytes_per_module: mean(
        modules.map(({ module }) => module.getWasmMemory().buffer.byteLength),
      ),
      rss_bytes_per_module: (modulesAfter.rss - modulesBefore.rss) / moduleCount,
      host_heap_bytes_per_module: (modulesAfter.heapUsed - modulesBefore.heapUsed) / moduleCount,
    },
    fib_quickjs_wasm: {
      guest_timed: guestTimed,
      host_timed_first_ms: hostTimed[0],
      host_timed_warm_ms: hostTimed.slice(1),
    },
    round_trip_between_runtimes: {
      round_trips: exchanges,
      warmup_round_trips: exchanges / 10,
      untimed_mean_ns: (untimedMs * 1e6) / exchanges,
      round_trips_per_s: exchanges / (untimedMs / 1000),
      latency_ns: {
        p50: percentileNs(0.5),
        p90: percentileNs(0.9),
        p99: percentileNs(0.99),
        p999: percentileNs(0.999),
      },
    },
  }),
);
