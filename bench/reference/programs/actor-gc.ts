// A long-running actor: 50,000 turns, each allocating garbage and replacing one of 1,000
// live entries. The realm collects between turns; the heap must stay bounded.
// Reference semantics only: heapStats is a prototype probe of "buoy".
import { heapStats, spawn } from "buoy";

class Cache {
  entries = new Map<number, { key: number; payload: number[] }>();
  last: unknown = null;

  put(n: number): number {
    for (let i = 0; i < 50; i++) {
      this.last = { i, data: [i, n] };
    }
    this.entries.set(n % 1000, { key: n, payload: [n, n * 2, n * 3] });
    return this.entries.size;
  }

  stats(): unknown {
    return heapStats();
  }
}

const cache = spawn(Cache);
const start = Date.now();
for (let turn = 1; turn <= 50000; turn++) {
  await cache.put(turn);
  if (turn % 10000 === 0) {
    const s = (await cache.stats()) as Record<string, number>;
    console.log(
      JSON.stringify({
        turn,
        ms: Date.now() - start,
        heap_entries: s.entries,
        allocated: s.allocated,
        live_at_last_gc: s.live,
        gc_runs: s.gcRuns,
        gc_max_us: s.gcMaxUs,
        gc_mean_us: Math.round(s.gcTotalUs / s.gcRuns),
        process_bytes: s.processBytes,
      }),
    );
  }
}
