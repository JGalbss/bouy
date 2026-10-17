// The memory of an actor with an empty realm: spawn 10,000 actors of an empty class.
// Reference semantics only: heapStats and vmMemory are prototype probes of "bouy".
import { heapStats, spawn, vmMemory } from "bouy";

class Empty {
  stats(): unknown {
    return heapStats();
  }
}

const N = 10000;
const before = vmMemory() as { total: number; processes: number };
const refs = [];
for (let i = 0; i < N; i++) refs.push(spawn(Empty));
const after = vmMemory() as { total: number; processes: number; processCount: number };
const one = (await refs[0].stats()) as { processBytes: number; entries: number };
console.log(
  JSON.stringify({
    bench: "realm-memory",
    actors: N,
    vm_bytes_per_actor: Math.round((after.total - before.total) / N),
    process_bytes_per_actor: Math.round((after.processes - before.processes) / N),
    one_actor_process_bytes: one.processBytes,
    one_actor_heap_entries: one.entries,
  }),
);
