# BEAM and OTP: the reference model, option A, and option D3

> Paths under `packages/`, `e2e/`, `examples/`, and `bench/` refer to commit [`90529d8`](https://github.com/JGalbss/bouy/tree/90529d8), the last commit with the Node runtime.

Track: beam. Date: 2026-10-16.

This note describes the BEAM and OTP mechanisms that Bouy wants to imitate. It then evaluates option A (TypeScript compiled to BEAM bytecode with a JavaScript compatibility layer) and option D3 (a BEAM host that runs JavaScript in NIFs or ports). Part 4 scores both options on the nine criteria. It also scores option C on the criteria where BEAM evidence applies. The last section lists the OTP semantics Bouy should copy and the parts that a JavaScript engine cannot copy.

## Evidence rules

- **Source** marks an external fact. A link follows it. Erlang documentation links point to the pages for OTP 29.1.2 (ERTS 17.1.1), the version those pages showed on 2026-10-16.
- **Measured** marks a number from a script that I ran on this machine. Appendix A holds each script and the command that ran it.
- **Unverified** marks a claim that I could not check. Each one names the check that would settle it.

| Item           | Value                                                                                                                                                    |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host           | Apple M5 Pro, 18 cores, 64 GB, macOS (Darwin 25.6.0)                                                                                                     |
| Linux VM       | OrbStack, Docker Engine 29.4.0, kernel `7.0.14-orbstack-00380-ga7e0a2dc9535`, 18 CPUs, 16,817,172,480 bytes of memory                                    |
| Erlang image   | `erlang:latest` = OTP 29.1.2, ERTS 17.1.1, JIT flavor, word size 8, digest `sha256:563a62a5…773692`. Defaults: 18 schedulers, 18 dirty CPU, 10 dirty I/O |
| Elixir image   | `elixir:latest` = Elixir 1.20.4 on OTP 29 (ERTS 17.1.1), Debian 13                                                                                       |
| Node in Docker | Node v25.9.0, copied from `node:25-trixie` into the Erlang image (A.7)                                                                                   |
| QuickBEAM      | 0.11.3 from Hex, precompiled `aarch64-linux-gnu` NIF                                                                                                     |
| npm packages   | zod 4.6.7 and ai 7.0.142, installed in `/tmp/bouy-beam-bench/compat` (outside the repository), bundled with esbuild 0.28.2                               |

- The scripts live in `/tmp/bouy-beam-bench/`. This track may write only this file, so Appendix A reproduces every script in full. `AGENTS.md` asks for benchmarks in `bench/` with recorded output. Moving these scripts to `bench/evidence/` is an open follow-up.
- Other agents ran benchmarks on the same host during these runs. The one-minute load average was 15 to 17 on 18 cores when I checked it during the last runs of A.7 and A.8. Each table gives the range across runs, so the noise is visible.
- Latency samples move in steps of about 42 ns. [measurements-beam-quickjs.md](measurements-beam-quickjs.md) reports the same 41.67 ns step.
- My BEAM spawn, memory, and round-trip numbers agree with [measurements-beam-quickjs.md](measurements-beam-quickjs.md), which used separate scripts.

## Key findings

1. BEAM gives each process its own heap and garbage collector. It preempts a process after 4,000 reductions. Measured on OTP 29: every one of 1,999 sampled slices was exactly 4,000 reductions, and a slice took 2.7 µs to 21 µs.
2. The BEAM collector relies on immutable terms. Its documentation says that "no term on the old heap may refer to a term on the young heap" and that this holds "because the terms are immutable" ([GC](https://www.erlang.org/doc/apps/erts/garbagecollection.html)). JavaScript objects therefore cannot be plain BEAM terms. Option A must keep a mutable heap inside each process and collect it itself, as Luerl does for Lua.
3. Hand-compiled JavaScript mutation in Erlang ran 13 to 16 times slower than V8 with its JIT when objects lived in a map heap. The process dictionary gave 27 to 32 times and ETS gave 72 to 91 times. Erlang without objects ran at 0.77 to 1.11 times the V8 time.
4. The only JavaScript-on-BEAM interpreter I found running today, `QuickBEAM.VM`, ran 112 to 155 times slower than native QuickJS. It stopped on zod 4.6.7 with `ReferenceError: BigInt is not defined` after 64.8 s.
5. A NIF runs outside BEAM preemption. A 100 ms NIF on the only scheduler raised the message round trip from 0.5 µs to 200 ms. The same NIF on a dirty scheduler left it at 0.5 µs. A segfault in a NIF ended the VM. The same signal in a port program left the VM running.
6. QuickBEAM embeds QuickJS-NG through NIFs and runs JavaScript on its own threads. It passed 4 of 4 zod checks and 3 of 4 AI SDK checks. `streamText` hung because `ReadableStream` with a `pull()` source never delivers in QuickBEAM 0.11.3.
7. A bare QuickBEAM context costs 274 µs to 345 µs and about 319 KiB of RSS. An idle BEAM process costs 2,632 bytes. A QuickBEAM call takes 13 µs to 36 µs at the median, against 0.5 µs for a BEAM round trip.
8. QuickBEAM contexts that share a thread get no fairness from each other. A busy loop in one context delayed another context by 1,898 ms. The BEAM schedulers stayed at a 0.75 µs p99 round trip, because no JavaScript ran on them.
9. A Node.js process behind an Erlang port took 10 ms to 35 ms to start and used about 40 MiB of RSS. A 16-byte round trip took 4.5 µs to 6.7 µs at the median.

## Part 1. BEAM and OTP as the reference model

### 1.1 Process creation cost and memory

- Source: "A newly spawned Erlang process uses 327 words of memory." The size "includes 233 words for the heap area (which includes the stack)" ([efficiency guide](https://www.erlang.org/doc/system/eff_guide_processes.html)).
- Source: the default limit is 1,048,576 live processes, and `+P` changes it ([system limits](https://www.erlang.org/doc/system/system_limits.html), [erl flags](https://www.erlang.org/doc/apps/erts/erl_cmd.html)).
- Source: `erlang:hibernate/3` puts a process in "a wait state where its memory allocation has been reduced as much as possible", and it empties the call stack ([erlang module](https://www.erlang.org/doc/apps/erts/erlang.html)).
- Measured (A.1): `process_info(Pid, memory)` reports 2,624 bytes for an idle process (328 words) with a 233-word heap. The growth of `erlang:memory(processes_used)` was 2,627 to 2,636 bytes per process for 10,000 to 1,000,000 processes. At 1,000,000 processes it was 2,632 bytes in every run.
- Measured (A.1): a hibernated idle process reports 800 bytes with a 5-word heap. The growth per process was 820 to 829 bytes.
- Measured (A.1): one process spawned 10,000 to 1,000,000 processes at 0.63 µs to 1.58 µs per spawn.

### 1.2 Per-process heaps and garbage collection

- Source: BEAM uses "a per process generational semi-space copying collector using Cheney's copy collection algorithm together with a global large object space" ([GC](https://www.erlang.org/doc/apps/erts/garbagecollection.html)).
- Source: the stack and the heap share one memory block and grow toward each other. A collection starts when they meet ([GC](https://www.erlang.org/doc/apps/erts/garbagecollection.html)).
- Source: an old-heap term may never point to a young-heap term. The page says this "comes naturally for Erlang because the terms are immutable" ([GC](https://www.erlang.org/doc/apps/erts/garbagecollection.html)).
- Inference: the collector needs no write barrier, because no term can change after it is built.
- Source: binaries larger than 64 bytes live off-heap with a reference count. "All data in messages sent between Erlang processes is copied, except for refc binaries and literals on the same Erlang node" ([GC](https://www.erlang.org/doc/apps/erts/garbagecollection.html), [efficiency guide](https://www.erlang.org/doc/system/eff_guide_processes.html)).
- Source: `message_queue_data` selects where queued messages live. `off_heap` keeps them out of the process heap and its collections, and `on_heap` is the default ([erlang module](https://www.erlang.org/doc/apps/erts/erlang.html), [erl flags](https://www.erlang.org/doc/apps/erts/erl_cmd.html)).
- Source: the `max_heap_size` process flag sets a heap limit per process. With `kill` set, which is the default, the runtime sends "an untrappable exit signal with reason kill" when a collection finds the heap above the limit. The size counts queued messages that are part of the heap ([erlang module](https://www.erlang.org/doc/apps/erts/erlang.html)).
- Consequence: each collection scans the heap of one process. The documentation describes no collection that spans processes, except the reference counts of off-heap binaries.

### 1.3 Reduction-based preemption

- Source: `#define CONTEXT_REDS 4000 /* Swap process out after this number */` ([erl_vm.h](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_vm.h)).
- Source: "the reduction counter is normally incremented by one for each function and BIF call. A context switch is forced when the counter reaches the maximum number of reductions for a process (4000 reductions in Erlang/OTP 19.2 and later)" ([erlang:bump_reductions/1](https://www.erlang.org/doc/apps/erts/erlang.html)).
- Source: "Scheduling is pre-emptive. Regardless of priority, a process is pre-empted when it has consumed more than a certain number of reductions since the last time it was selected for execution." Four priority levels exist, and each level runs round robin. Nothing prevents priority inversion ([process_flag(priority)](https://www.erlang.org/doc/apps/erts/erlang.html)).
- Measured (A.3): on one scheduler, a sampler read the reduction count of a CPU-bound process after each of its slices. All 1,999 slices were exactly 4,000 reductions, for a call loop and for a map-update loop, in 3 runs.
- Measured (A.3): one slice plus the sampler took 2.7 µs for the call loop and 16 µs to 21 µs for the map-update loop. The `enif_consume_timeslice` documentation approximates the timeslice as "about 1 millisecond" ([erl_nif](https://www.erlang.org/doc/apps/erts/erl_nif.html)). The wall time of a slice depends on the work per reduction.
- Measured (A.3): on one scheduler, a ping-pong pair had a p50 of 0.5 µs and a p99 of 1.5 µs to 2.3 µs. With a CPU-bound process on the same scheduler, the p50 rose to 5.5 µs to 6.3 µs, the p99 to 23 µs to 36 µs, and the maximum to 102 µs to 137 µs.

### 1.4 Dirty schedulers and NIF limits on preemption

- Source: "A native function that crashes will crash the whole VM." The VM "cannot provide the same services as provided when executing Erlang code, such as pre-emptive scheduling or memory protection" ([erl_nif](https://www.erlang.org/doc/apps/erts/erl_nif.html)).
- Source: "a well-behaving native function is to return to its caller within 1 millisecond." Longer work must be split into a yielding NIF, moved to a thread that replies with `enif_send`, or marked as a dirty NIF ([erl_nif](https://www.erlang.org/doc/apps/erts/erl_nif.html)).
- Source: by default the dirty CPU schedulers equal the normal schedulers in number and cannot exceed them. There are 10 dirty I/O schedulers by default ([erl flags](https://www.erlang.org/doc/apps/erts/erl_cmd.html)). The container reported 18, 18, and 10.
- Source: a process in a dirty NIF cannot be suspended or garbage collected "until the dirty NIF has returned". When the process is killed, its links and monitors fire, but "the execution of the NIF is, however, not stopped" ([erl_nif](https://www.erlang.org/doc/apps/erts/erl_nif.html)).
- Measured (A.4): 1,000 calls of a trivial NIF cost 1,746 reductions, including the loop. A NIF call therefore costs less than 2 reductions, whatever its duration.
- Measured (A.4): a process that called a 100 ms busy-wait NIF in a loop held the only scheduler for more than 300 s. I stopped the run. At less than 2 reductions per call, one 4,000-reduction slice allows thousands of such calls.
- Measured (A.4): with `erlang:yield()` between NIF calls, a ping-pong pair on the same scheduler completed 11 round trips in 2 s, with a p50 of 200 ms. With the same NIF marked `ERL_NIF_DIRTY_JOB_CPU_BOUND`, the pair completed 3.0 to 3.5 million round trips in 2 s, with a p50 of 0.5 µs and a p99 of 0.8 µs to 0.9 µs.
- Measured (A.4): a NIF that dereferences a null pointer ended the VM with `Segmentation fault` and exit code 139. A port program that sent itself SIGSEGV gave the VM `{exit_status, 139}`, and the VM kept running.
- Source: a port runs an external program in another OS process. If the port owner terminates, the port closes too ([ports](https://www.erlang.org/doc/system/ports.html)).
- Source: Rustler "catches rust panics before they unwind into C" ([Rustler README](https://github.com/rusterlium/rustler)). This protects against Rust panics only. A memory fault inside a C engine such as QuickJS still ends the VM, by the rule above.

### 1.5 Mailbox semantics and signal ordering

- Source: "The only signal ordering guarantee given is the following: if an entity sends multiple signals to the same destination entity, the order is preserved." The time to arrival is "unspecified but positive". Over the distribution, "signals can be lost if the distribution channel goes down", and "S1 may or may not have been lost" ([processes](https://www.erlang.org/doc/system/ref_man_processes.html)).
- Source: signal reception "is not tied to the execution of a receive expression". Messages go to the end of the queue unless the receiver enabled priority messages ([processes](https://www.erlang.org/doc/system/ref_man_processes.html)).
- Source: since OTP 28, a process can create a priority alias. A message sent through it with the `priority` option goes after the last priority message in the queue. The page warns that "You very seldom need to resort to usage of priority messages" ([processes](https://www.erlang.org/doc/system/ref_man_processes.html)).
- Source: OTP 25 added a many-to-one optimization for receivers with `off_heap` message data. Senders hash into 64 buffers instead of taking one lock. The per-pair guarantee is what allows this. The author reports 520 times the receive throughput for 16 senders of small messages on a 64-thread machine ([Winblad, 2021-11-05](https://www.erlang.org/blog/parallel-signal-sending-optimization/)).
- Measured (A.2): send and receive round trips had a mean of 0.48 µs to 0.60 µs, a p50 of 0.42 µs to 0.54 µs, and a p99 of 0.92 µs to 1.50 µs.
- Measured (A.2): throughput into one receiver, in million messages per second:

| Payload                         | 1 sender, `on_heap` | 16 senders, `on_heap` | 1 sender, `off_heap` | 16 senders, `off_heap` |
| ------------------------------- | ------------------- | --------------------- | -------------------- | ---------------------- |
| Small integer                   | 8.8 to 10.0         | 1.8 to 2.3            | 8.9 to 11.9          | 16.7 to 20.7           |
| Tuple of 100 integers (copied)  | 3.5 to 4.0          | 0.77 to 1.61          | 3.0 to 4.2           | 2.6 to 3.5             |
| 1 KiB binary (shared, refcount) | 6.1 to 7.8          | 1.5 to 2.0            | 6.1 to 7.2           | 9.1 to 11.0            |

### 1.6 Selective receive

- Source: a receive that matches only some messages searches "the entire message queue" until it finds a match, which is "very expensive for processes with long message queues". The compiler skips the old messages when every clause matches a reference created just before the send ([efficiency guide](https://www.erlang.org/doc/system/eff_guide_processes.html)).
- Measured (A.5): a receive for `{target, _}` behind K unmatched messages took 0.08 µs at K = 0, 2.4 µs at K = 1,000, 22 µs to 23 µs at K = 10,000, and 256 µs to 268 µs at K = 100,000. That is about 2.6 ns per skipped message.
- Measured (A.5): a receive for a reference made with `make_ref()` before the send took 0.08 µs to 0.13 µs at every K. The compiler printed `OPTIMIZED: all clauses match reference created by make_ref/0` with `+recv_opt_info`.

### 1.7 Links, monitors, and aliases

- Source: links are bidirectional, and two processes have at most one link. `spawn_link` creates the process and the link atomically ([processes](https://www.erlang.org/doc/system/ref_man_processes.html)).
- Source: a process that is not trapping exits dies on any exit reason except `normal`. A trapping process gets `{'EXIT', From, Reason}` as a message. Reason `kill` sent with `exit_signal/2` cannot be trapped and ends the receiver with reason `killed`. A link across nodes yields `noconnection` when the connection fails ([processes](https://www.erlang.org/doc/system/ref_man_processes.html)).
- Source: OTP 29 documents `exit_signal/2` as the BIF that sends an exit signal ([erlang module](https://www.erlang.org/doc/apps/erts/erlang.html)).
- Source: monitors are unidirectional, and each `monitor/2` call creates an independent monitor. A monitor on a process that does not exist delivers `{'DOWN', Ref, process, Pid, noproc}` at once ([processes](https://www.erlang.org/doc/system/ref_man_processes.html)).
- Source: after an alias is deactivated, "messages sent using the alias will be dropped before entering the message queue" ([processes](https://www.erlang.org/doc/system/ref_man_processes.html)).
- See [actor-models.md](actor-models.md) A.2: on OTP 29, a restarted child gets a new pid and the messages in the old mailbox are lost.

### 1.8 Supervisors

- Source: the strategies are `one_for_one` (the default), `one_for_all`, `rest_for_one`, and `simple_one_for_one` ([supervisor](https://www.erlang.org/doc/apps/stdlib/supervisor.html)).
- Source: "if more than MaxR restarts occur within MaxT seconds, the supervisor terminates all child processes and then itself". `intensity` defaults to 1 and `period` to 5 ([supervisor](https://www.erlang.org/doc/apps/stdlib/supervisor.html)).
- Source: a `permanent` child always restarts, and a `temporary` child never restarts. A `transient` child restarts only after an exit reason other than `normal`, `shutdown`, or `{shutdown, Term}`. The default is `permanent` ([supervisor](https://www.erlang.org/doc/apps/stdlib/supervisor.html)).
- Source: `shutdown` is `brutal_kill` or a timeout. The supervisor sends `shutdown`, waits, and then kills. The default is 5,000 ms for a worker and `infinity` for a supervisor ([supervisor](https://www.erlang.org/doc/apps/stdlib/supervisor.html)).
- Source: children start in list order and stop in reverse order ([supervision principles](https://www.erlang.org/doc/system/sup_princ.html)).
- Source: `auto_shutdown` set to `any_significant` or `all_significant` stops the supervisor when significant children end. The default is `never` ([supervisor](https://www.erlang.org/doc/apps/stdlib/supervisor.html)).
- Source: "the total number of restarts (before the top level supervisor gives up and terminates the application) will be the product of the intensity values of all the supervisors above the failing child process" ([supervision principles](https://www.erlang.org/doc/system/sup_princ.html)).
- Measured (A.6): a `one_for_one` supervisor replaced a killed worker, and the worker registered its name again, 10,000 times per run. With logging on, the mean was 52 µs to 55 µs and the p99 was 132 µs to 136 µs. With logging off, the mean was 38 µs to 45 µs and the p99 was 138 µs to 158 µs.

### 1.9 gen_server call and cast

- Source: `call/2` waits 5,000 ms. On timeout it "exits the calling process with an exit term containing Reason = timeout". Other reasons are `noproc`, `{nodedown, Node}`, `calling_self`, and `shutdown` ([gen_server](https://www.erlang.org/doc/apps/stdlib/gen_server.html)).
- Source: "Starting with OTP 24, gen_server:call uses process aliases, so late replies will not be received" ([gen_server](https://www.erlang.org/doc/apps/stdlib/gen_server.html)).
- Source: `cast/2` "returns ok immediately, ignoring if the destination node or gen_server process does not exist" ([gen_server](https://www.erlang.org/doc/apps/stdlib/gen_server.html)).
- Source: the `gen_server` page gives the server no way to learn that the caller timed out. [actor-models.md](actor-models.md) reaches the same conclusion from the same page.
- Measured (A.2): a `gen_server:call` round trip had a mean of 0.76 µs to 1.13 µs.

### 1.10 Distribution

- Source: distribution runs over TCP/IP. Pids, links, and monitors work across nodes, but registered names are local to a node. Connections are transitive by default ([distributed Erlang](https://www.erlang.org/doc/system/distributed.html)).
- Source: the magic cookie guards "against accidental misuse" only, and traffic is clear text by default. A node started without `-proto_dist inet_tls` is exposed "to attacks that may give the attacker complete access to the node" ([distributed Erlang](https://www.erlang.org/doc/system/distributed.html)).
- Source: `net_ticktime` defaults to 60 s with an intensity of 4, so a dead peer is detected after 45 s to 75 s ([kernel](https://www.erlang.org/doc/apps/kernel/kernel_app.html)).
- Source: the distribution protocol relies on the same per-pair ordering guarantee for signals between nodes ([distribution protocol](https://www.erlang.org/doc/apps/erts/erl_dist_protocol.html)). A sender is suspended when the channel buffer passes the busy limit, 1,024 KB by default. `process_flag(async_dist, true)` removes that suspension per process ([processes](https://www.erlang.org/doc/system/ref_man_processes.html), [erl flags](https://www.erlang.org/doc/apps/erts/erl_cmd.html)).
- Source: `global` keeps a replica of the name table on every node. Registration and locks are atomic, and a user function resolves name clashes after a partition heals. Since OTP 25, `global` prevents overlapping partitions by default ([global](https://www.erlang.org/doc/apps/kernel/global.html)).
- Not measured.

### 1.11 Hot code loading

- Source: a module can have a current and an old version at once. "Fully qualified function calls always refer to current code." Loading a third version purges the old one, and "any processes lingering in it are terminated" ([code loading](https://www.erlang.org/doc/system/code_loading.html)).
- Source: a fun survives replacement only in the `fun Module:FunctionName/Arity` form ([code loading](https://www.erlang.org/doc/system/code_loading.html)).
- Source: `gen_server` has an optional `code_change/3` callback that converts state during a release upgrade or downgrade. SASL release handling builds on code replacement ([gen_server](https://www.erlang.org/doc/apps/stdlib/gen_server.html), [release handling](https://www.erlang.org/doc/system/release_handling.html)).

### 1.12 The BEAM JIT

- Source: John Högberg described the JIT in a blog post on 2020-11-03. Each BEAM instruction gets a handwritten machine-code template ([blog](https://www.erlang.org/blog/a-first-look-at-the-jit/)).
- Source: OTP 24.0 (2021-05-12) added BeamAsm, "enabled by default on most x86 64-bit platforms" ([OTP 24.0](https://www.erlang.org/news/148)). OTP 25.0 (2022-05-18) states "The JIT now works for 64-bit ARM processors" and adds type-based optimizations ([OTP 25.0](https://erlang.org/news/157)).
- Source: BeamAsm converts BEAM instructions at load time and "does hardly any cross instruction optimizations". Loaded code uses about 10% more memory than the interpreter. `+JPperf true` exposes symbols to Linux `perf` ([BeamAsm](https://www.erlang.org/doc/apps/erts/beamasm.html)).
- Measured: `erlang:system_info(emu_flavor)` returned `jit` in the arm64 container.
- Inference: BeamAsm does not speculate on types at run time. Code that dispatches on dynamic JavaScript types gets no inline caches from the VM.

## Part 2. Option A: TypeScript to BEAM bytecode

### 2.1 How JavaScript semantics map onto the BEAM

| JavaScript feature                           | BEAM mechanism and cost                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Mutable objects and prototypes               | BEAM terms are immutable (1.2). An object must be an entry in an emulated heap: a map threaded through every call, the process dictionary, or ETS. ETS copies the object on "every object insert and look-up" ([ets](https://www.erlang.org/doc/apps/stdlib/ets.html)). Each property read walks the prototype chain in that heap. Section 2.2 measures the cost.                                                                                                                                                                                             |
| Garbage collection of objects                | The BEAM collector sees the whole emulated heap as one live term, so it cannot free an unreachable object inside it. The runtime needs its own collector. Luerl runs its own mark-and-sweep pass over its Lua tables ([luerl_heap.erl](https://github.com/rvirding/luerl/blob/develop/src/luerl_heap.erl)). QuickBEAM's BEAM interpreter states that its memory "Accounting is monotonic until garbage collection is implemented" ([memory.ex](https://github.com/elixir-volt/quickbeam/blob/master/lib/quickbeam/vm/runtime/memory.ex)).                     |
| Closures over mutable variables              | An Erlang fun captures values. A captured `let` that changes needs a boxed cell in the emulated heap. Luerl keeps such variables "in the global heap as each invocation can modify them" ([Luerl NOTES](https://github.com/rvirding/luerl/blob/develop/src/NOTES)).                                                                                                                                                                                                                                                                                           |
| Getters, setters, `Object.defineProperty`    | Each property access becomes a runtime call that checks for an accessor. zod 4.6.7 has 40 `Object.defineProperty` sites, and the AI SDK has 103 getter or setter definitions (2.3).                                                                                                                                                                                                                                                                                                                                                                           |
| `Proxy` and `Reflect`                        | Every object operation must dispatch through traps when the target is a proxy. The AI SDK has 12 `new Proxy` sites and zod has 28 `Reflect` calls (2.3).                                                                                                                                                                                                                                                                                                                                                                                                      |
| Numbers                                      | JavaScript numbers are IEEE 754 binary64 values, including NaN and the infinities ([ECMAScript 2027 draft](https://tc39.es/ecma262/multipage/ecmascript-data-types-and-values.html)). "neither Inf nor NaN are supported in Erlang", and an operation that would produce them raises `badarith` ([data types](https://www.erlang.org/doc/system/data_types.html)). Every arithmetic operation needs a guarded path unless the compiler proves the operands are safe. Bitwise operators need 32-bit masking, because Erlang integers have arbitrary precision. |
| Strings                                      | A JavaScript string is a sequence of "16-bit unsigned integer values" ([ECMAScript 2027 draft](https://tc39.es/ecma262/multipage/ecmascript-data-types-and-values.html)). Erlang strings are usually UTF-8 binaries. `length`, `charCodeAt`, and lone surrogates need a UTF-16 view. QuickBEAM's interpreter has a separate UTF-16 module for this ([source tree](https://github.com/elixir-volt/quickbeam/tree/master/lib/quickbeam/vm/runtime/string)).                                                                                                     |
| Property order                               | `maps:keys/1` returns keys "in any order" ([maps](https://www.erlang.org/doc/apps/stdlib/maps.html)). JavaScript defines the order of own keys, so the runtime must record insertion order.                                                                                                                                                                                                                                                                                                                                                                   |
| Typed arrays and `ArrayBuffer`               | Erlang binaries are immutable. `atomics` arrays are mutable but hold only 64-bit integers ([atomics](https://www.erlang.org/doc/apps/erts/atomics.html)). Fable's BEAM target uses `atomics` for F# byte arrays ([Fable](https://fable.io/docs/beam/compatibility.html)). The AI SDK refers to `Uint8Array`, `ArrayBuffer`, or `DataView` 43 times (2.3).                                                                                                                                                                                                     |
| `WeakMap`, `WeakRef`, `FinalizationRegistry` | I found no weak reference in the `erlang`, `ets`, or `persistent_term` documentation. Weak semantics therefore depend on the emulated heap's own collector. zod uses `WeakMap` or `WeakSet` 10 times.                                                                                                                                                                                                                                                                                                                                                         |
| Promises and the microtask queue             | A Job "must run to completion before evaluation of any other Job starts in an agent" ([ECMAScript 2027 draft](https://tc39.es/ecma262/multipage/executable-code-and-execution-contexts.html)). Inference: if each actor is one BEAM process and one agent, BEAM preemption inside a job is invisible to that actor. The job queue can be a list in the process state. The mutable module state of every npm package then exists once per actor.                                                                                                               |
| `async`/`await` and generators               | The compiler must turn suspended functions into state machines or continuations. Fable compiles F# async to continuation-passing style and does not preserve the hot start of .NET tasks ([Fable](https://fable.io/docs/beam/compatibility.html)).                                                                                                                                                                                                                                                                                                            |
| Event loop and timers                        | A process `receive` loop plus `erlang:send_after` can host one event loop per actor. Inference: this part needs no emulated heap.                                                                                                                                                                                                                                                                                                                                                                                                                             |
| Node APIs (`fs`, `net`, `http`, streams)     | Each API must be rewritten over `file`, `gen_tcp`, `socket`, `ssl`, and an HTTP client. QuickBEAM shows the size of this work for its native engine: `fetch` over `:httpc`, `WebSocket` over Mint, and streams in TypeScript ([README](https://github.com/elixir-volt/quickbeam/blob/master/README.md)).                                                                                                                                                                                                                                                      |
| Native modules (Node-API)                    | Node-API is "independent from the underlying JavaScript runtime" but needs an implementation of its C functions ([Node-API](https://nodejs.org/api/n-api.html)). Option A has no JavaScript engine to implement them on, so `.node` addons cannot load.                                                                                                                                                                                                                                                                                                       |
| `eval` and `new Function`                    | An ahead-of-time compiler needs a JavaScript compiler or interpreter at run time to support them. zod probes `new F("")` and uses its slower path when the probe fails ([util.js](https://github.com/colinhacks/zod/blob/main/packages/zod/src/v4/core/util.ts)), so zod can run without it.                                                                                                                                                                                                                                                                  |

### 2.2 Measured cost of emulated mutation

The workload is a JavaScript loop that increments an object property and calls a closure that updates a captured `let`. A.8 compiles it by hand into four Erlang shapes. V8 runs the original JavaScript in the same container, right after the Erlang variants. Each cell is the median of 5 timed runs of 1,000,000 iterations, shown as a range across 5 container runs. The ratio column divides by the V8 time from the same container run.

| Variant                                | ms per 1,000,000 iterations | Ratio to V8 with JIT, per run |
| -------------------------------------- | --------------------------- | ----------------------------- |
| Erlang, values in registers, no heap   | 1.20 to 1.71                | 0.77 to 1.11                  |
| Erlang, heap as a map passed along     | 19.19 to 27.25              | 13.4 to 16.3                  |
| Erlang, heap in the process dictionary | 37.13 to 51.00              | 27.0 to 32.4                  |
| Erlang, heap in ETS                    | 110.06 to 135.08            | 71.5 to 91.0                  |
| V8 14.1 with JIT (Node v25.9.0)        | 1.30 to 1.89                | 1                             |
| V8 14.1 with `--jitless`               | 19.26 to 24.64              | 13.0 to 18.7                  |

- The hand-compiled Erlang has no property descriptors, no prototype lookup, and no NaN guard. A real compiler adds those checks, so these ratios are lower bounds for the map heap.
- When the compiler can remove the object entirely, Erlang ran at 0.77 to 1.11 times the V8 time. That case covers values that never leave a function.
- Measured (A.9): `QuickBEAM.VM`, a BEAM interpreter for QuickJS bytecode, ran the same workload at 100,000 iterations in 689 ms. Native QuickJS in the same release took 4.45 ms, 155 times less. For `fib(20)` the ratio was 144, and for `fib(24)` it was 112.

### 2.3 What zod and the Vercel AI SDK need from the runtime

Measured (A.10): a scan of the installed builds counts these constructs.

| Construct                               | zod 4.6.7 (`v4/core`, `v4/classic`) | ai 7.0.142 | @ai-sdk/provider-utils 5.0.61 | @ai-sdk/openai 4.0.95 |
| --------------------------------------- | ----------------------------------- | ---------- | ----------------------------- | --------------------- |
| `Object.defineProperty`                 | 40                                  | 2          | 2                             | 0                     |
| Getter or setter definitions            | 20                                  | 103        | 3                             | 16                    |
| `new Proxy`                             | 1                                   | 12         | 0                             | 0                     |
| `Reflect.*`                             | 28                                  | 0          | 0                             | 0                     |
| `WeakMap` or `WeakSet`                  | 10                                  | 2          | 0                             | 0                     |
| `await`                                 | 13                                  | 534        | 63                            | 116                   |
| Generator functions                     | 1                                   | 0          | 3                             | 0                     |
| `new Function` or `new F(`              | 6                                   | 0          | 0                             | 0                     |
| `fetch(`                                | 0                                   | 3          | 7                             | 0                     |
| `ReadableStream` / `TransformStream`    | 0 / 0                               | 27 / 37    | 8 / 2                         | 2 / 3                 |
| `TextEncoder` or `TextDecoder`          | 0                                   | 13         | 6                             | 0                     |
| `AbortController` or `AbortSignal`      | 0                                   | 21         | 1                             | 0                     |
| `setTimeout` or `clearTimeout`          | 0                                   | 29         | 2                             | 2                     |
| `structuredClone`                       | 0                                   | 7          | 0                             | 0                     |
| `Uint8Array`, `ArrayBuffer`, `DataView` | 2                                   | 43         | 21                            | 3                     |
| `node:` built-in specifiers             | 0                                   | 3          | 2                             | 0                     |

- Source: ai 7.0.142 checks `process.release?.name === "node"` before it loads `node:diagnostics_channel` and `node:async_hooks` through `process.getBuiltinModule`. Without Node it skips tracing. @ai-sdk/provider-utils 5.0.61 uses `globalThis.fetch` outside Node and loads `undici` through `createRequire` inside Node (`dist/index.js` of each package; [ai on GitHub](https://github.com/vercel/ai)).
- Consequence: outside Node, the AI SDK needs only web-standard APIs from the host. Option A must still implement `fetch`, WHATWG streams, `TextDecoder`, `AbortSignal`, `structuredClone`, and timers on the emulated heap.
- Measured (A.10): the probe passes 8 of 8 checks on Node v25.9.0, both from TypeScript source and from the esbuild bundle.

### 2.4 Prior art for JavaScript on the BEAM, and the reverse

| Project                                        | Direction and method                                             | What it achieved                                                                                                                                                                                                                                                                                                                                                         | Status                                                                                                                                                                                                                                          |
| ---------------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ActionScript (ECMAScript 4) to Erlang compiler | JS-family source to Erlang, 2007                                 | Announced by Joel Reymont with Roberto Saccon, starting from a partial grammar ([erlang-questions, 2007-10](https://erlang.org/pipermail/erlang-questions/2007-October/029979.html))                                                                                                                                                                                     | No release found. Unverified: the hosting at `code.google.com/p/jserl` is gone.                                                                                                                                                                 |
| erlyjs                                         | ECMAScript on the BEAM                                           | A 2012 post says erlyjs was "interpreting the ECMAscript on the beam machine" ([erlang-questions, 2012-06-22](https://erlang.org/pipermail/erlang-questions/2012-June/067597.html))                                                                                                                                                                                      | Unverified: I did not find its source or a last commit.                                                                                                                                                                                         |
| `QuickBEAM.VM` (QuickBEAM 0.11)                | Interprets QuickJS bytecode in Erlang/Elixir                     | "a bounded, tested JavaScript subset" with fresh heaps per call ([README](https://github.com/elixir-volt/quickbeam/blob/master/README.md)). Measured: 112 to 155 times slower than native QuickJS, and zod 4.6.7 fails on `BigInt` after 64.8 s (A.9).                                                                                                                   | Active. Its compiler tier is "release-quarantined". It has no collector yet.                                                                                                                                                                    |
| Luerl                                          | Lua 5.3 in Erlang                                                | Tables and closure variables live in an explicit heap with its own mark-and-sweep collector ([NOTES](https://github.com/rvirding/luerl/blob/develop/src/NOTES), [luerl_heap.erl](https://github.com/rvirding/luerl/blob/develop/src/luerl_heap.erl))                                                                                                                     | Active, last push 2026-10-15 (GitHub API).                                                                                                                                                                                                      |
| Fable BEAM target                              | F# to Erlang source                                              | Arrays, lists, and dictionaries become "process dictionary references". Interfaces become maps of closures. `async` becomes continuation-passing style. `MailboxProcessor` runs on "an in-process CPS continuation model", not on BEAM processes ([compatibility](https://fable.io/docs/beam/compatibility.html), [features](https://fable.io/docs/beam/features.html)). | "Beam target is in alpha", added in Fable 5.0.0-rc.1.                                                                                                                                                                                           |
| purerl                                         | PureScript to Erlang source                                      | A typed, pure language maps onto BEAM terms without an emulated heap ([README](https://github.com/purerl/purerl))                                                                                                                                                                                                                                                        | The README now recommends the newer `purescript-backend-erl`.                                                                                                                                                                                   |
| Caramel                                        | OCaml to Erlang                                                  | Type-safe interop with Erlang and Elixir ([README](https://github.com/leostera/caramel))                                                                                                                                                                                                                                                                                 | Archived; last push 2023-09-25 (GitHub API). Unverified: no stated reason.                                                                                                                                                                      |
| Lumen, renamed Firefly                         | Erlang to native code and WebAssembly, runtime in Rust           | Hot code loading and dynamic code loading were non-goals ([README](https://github.com/GetFirefly/firefly))                                                                                                                                                                                                                                                               | Archived; last push 2023-10-18 (GitHub API). A newsletter says the main developer "was swamped at work" ([Underjord 105](https://underjord.io/newsletters/underjord/underjord-newsletter-105.html)). Unverified: no maintainer statement found. |
| Gleam JavaScript target                        | Reverse: Gleam to JavaScript                                     | `gleam_erlang`'s `process.gleam` has 34 Erlang externals and 0 JavaScript externals ([process.gleam](https://github.com/gleam-lang/erlang/blob/main/src/gleam/erlang/process.gleam)). A function without an external for the target cannot compile for it ([externals](https://gleam.run/documentation/externals/)).                                                     | Active. Processes exist only on the Erlang target.                                                                                                                                                                                              |
| ElixirScript                                   | Reverse: Elixir to JavaScript                                    | Converts "a subset (or full set) of Elixir code" to JavaScript ([README](https://github.com/elixirscript/elixirscript))                                                                                                                                                                                                                                                  | Last push 2019-08-20 (GitHub API). Unverified: no stated reason.                                                                                                                                                                                |
| Hologram                                       | Reverse: Elixir to JavaScript for browser code                   | Its author says it "transpiles BEAM definitions directly to JavaScript" ([Elixir Forum](https://elixirforum.com/t/how-is-firefly-going/58134))                                                                                                                                                                                                                           | Active.                                                                                                                                                                                                                                         |
| Popcorn                                        | Reverse: a BEAM compiled to WebAssembly inside a JavaScript host | "runs Elixir and Erlang applications in the browser on a BEAM virtual machine compiled to WebAssembly" ([README](https://github.com/software-mansion/popcorn))                                                                                                                                                                                                           | 1.0 is a prerelease. The stable 0.3 channel uses AtomVM.                                                                                                                                                                                        |

Lessons from the prior art:

- Each project in the table that compiles a mutating language to the BEAM models mutation explicitly. Luerl and `QuickBEAM.VM` pass a heap of objects through the interpreter state, and Fable stores mutable collections in the process dictionary.
- Fable runs `MailboxProcessor` with continuations inside one BEAM process. It does not map that actor type onto BEAM processes.
- I found no project that runs unmodified npm packages such as zod on the BEAM without an embedded JavaScript engine.
- The reverse direction works only by shipping a BEAM, as Popcorn does, or by dropping processes, as Gleam and ElixirScript do.

## Part 3. Option D3: a BEAM host with JavaScript in NIFs or ports

### 3.1 Variants

- **Engine call on a normal scheduler.** 1.4 shows that one long call blocks every process on that scheduler. This variant fails the 1 ms rule.
- **Engine on dirty schedulers.** Denox runs `deno_runtime` (V8) through Rustler. "All NIFs run on dirty CPU schedulers", and "Each runtime gets a dedicated OS thread" ([Denox README](https://readme.hex.pm/denox/0.9.0)).
- **Engine on its own threads.** QuickBEAM runs QuickJS-NG on worker threads through Zig NIFs. Each runtime is a GenServer ([AGENTS.md](https://github.com/elixir-volt/quickbeam/blob/master/AGENTS.md), [README](https://github.com/elixir-volt/quickbeam/blob/master/README.md)). A `ContextPool` puts many contexts on a few threads.
- **External OS processes behind ports.** elixir-nodejs supervises a pool of Node.js processes ([README](https://github.com/revelrylabs/elixir-nodejs)). erlang_v8 runs V8 "in an external OS process" ([repository](https://github.com/strange/erlang_v8)).

### 3.2 QuickBEAM measurements

Measured (A.9), QuickBEAM 0.11.3, 3 runs unless noted:

| Unit                                     | Create time      | RSS growth per unit | QuickJS allocation (1 run)              | OS threads |
| ---------------------------------------- | ---------------- | ------------------- | --------------------------------------- | ---------- |
| Runtime, `apis: false`                   | 468 µs to 617 µs | 558 to 732 KiB      | 129,920 bytes (`malloc_size`)           | 1 each     |
| Runtime, browser APIs                    | 5.7 ms to 9.2 ms | 1,164 to 1,259 KiB  | 732,224 bytes (`malloc_size`)           | 1 each     |
| Context in a 4-thread pool, bare         | 274 µs to 345 µs | 319 to 320 KiB      | 88,544 bytes (`context_malloc_size`)    | 0 added    |
| Context in a 4-thread pool, browser APIs | 4.3 ms to 5.4 ms | 737 to 739 KiB      | 1,092,200 bytes (`context_malloc_size`) | 0 added    |

| Operation                                             | Mean           | p50            | p99             |
| ----------------------------------------------------- | -------------- | -------------- | --------------- |
| `QuickBEAM.eval(rt, "1 + 2")`                         | 18 µs to 26 µs | 15 µs to 20 µs | 77 µs to 143 µs |
| `QuickBEAM.call(rt, "f", [map])`                      | 22 µs to 53 µs | 18 µs to 36 µs | 85 µs to 191 µs |
| `QuickBEAM.Context.eval(ctx, "1 + 2")`                | 20 µs to 39 µs | 13 µs to 28 µs | 77 µs to 135 µs |
| `Beam.callSync` from JavaScript to an Elixir function | 10 µs to 24 µs | not recorded   | not recorded    |

Fairness, one run:

- Two contexts shared a one-thread pool. While the first ran `for (;;) { i++ }` with a 2,000 ms timeout, an eval in the second waited 1,897.8 ms.
- The first eval returned `{:error, %QuickBEAM.JSError{message: "interrupted"}}`. The same context then returned `{:ok, 42}` for `40 + 2`.
- Two runtimes have one thread each. While one looped, an eval in the other took 0.145 ms.
- A BEAM ping-pong pair had a p99 of 0.88 µs before the loop and 0.75 µs during it.
- Source: QuickJS-NG polls its interrupt handler every 10,000 counter steps. A positive answer throws an uncatchable `InternalError: interrupted` ([quickjs.c](https://github.com/quickjs-ng/quickjs/blob/master/quickjs.c), `JS_INTERRUPT_COUNTER_INIT` and `JS_ThrowInterrupted`). QuickJS can stop a script but cannot suspend and resume it.
- Source: V8's `RequestInterrupt` runs a callback and then returns control to the script, and the callback "must not reenter interrupted Isolate". `TerminateExecution` ends the current execution ([v8-isolate.h](https://chromium.googlesource.com/v8/v8/+/refs/heads/main/include/v8-isolate.h)).

### 3.3 Node.js behind an Erlang port

Measured (A.7): the port uses `{packet, 4}` framing and 16-byte payloads. `cat` is the floor for a pipe round trip. `cat` ran twice. `node` ran five times, and the last three runs saw a load average of 15 to 17.

| Port program    | Start to first echo (median of 10) | RSS                  | Round trip p50   | Round trip p99 | Pipelined messages per second |
| --------------- | ---------------------------------- | -------------------- | ---------------- | -------------- | ----------------------------- |
| `cat`           | 0.7 ms to 0.8 ms (0.5 to 1.1)      | 1,212 KiB            | 2.8 µs to 3.0 µs | 23 µs to 34 µs | 1.60 to 1.71 million          |
| `node echo.mjs` | 11.0 ms to 20.1 ms (10.2 to 35.3)  | 41,092 to 41,124 KiB | 4.5 µs to 6.7 µs | 21 µs to 49 µs | 0.34 to 1.16 million          |

- One Node.js process per actor costs as much memory as about 16,000 idle BEAM processes. That figure is 41,104 KiB (42,090,496 bytes) divided by 2,632 bytes.
- A pool of Node.js processes brings the actors back into a shared isolate, which is option C inside a BEAM host.

### 3.4 npm compatibility under QuickBEAM

Measured (A.9, A.10): the same probe that passes 8 of 8 on Node v25.9.0.

| Check                                         | QuickBEAM 0.11.3, `apis: [:browser]` | QuickBEAM 0.11.3, `apis: [:browser, :node]` |
| --------------------------------------------- | ------------------------------------ | ------------------------------------------- |
| zod: parse with a transform                   | pass                                 | pass                                        |
| zod: `safeParse` issue count                  | pass                                 | pass                                        |
| zod: `toJSONSchema`                           | pass                                 | pass                                        |
| zod: async refine                             | pass                                 | pass                                        |
| ai: `generateText` with `MockLanguageModelV4` | pass                                 | pass                                        |
| ai: `streamText` and `textStream`             | fail: "Promise resolution timeout"   | fail: "Promise resolution timeout"          |
| ai: tool loop with a zod input schema         | pass                                 | pass                                        |
| ai: `Output.object` with a zod schema         | pass                                 | pass                                        |

- Measured (A.9): `ReadableStream` with a `pull()` source never resolved `read()` within 3 s. Streams fed from `start()`, `for await`, `pipeThrough`, and `tee()` worked. `simulateReadableStream` in ai 7.0.142 uses `pull()`, which explains the failed check.
- Measured (A.9): QuickBEAM's own bundler (`QuickBEAM.JS.bundle_file`) failed with 4 errors such as "Could not resolve './get-vercel-oidc-token'" in `@vercel/oidc` 3.2.0. That package uses CommonJS `require` without file extensions. The engine checks above use an esbuild bundle instead.
- Source: QuickBEAM implements Node-API on QuickJS-NG and tests it with `@node-rs/crc32`, `@node-rs/argon2`, `@node-rs/bcrypt`, and `sqlite-napi` ([CHANGELOG 0.8.0](https://github.com/elixir-volt/quickbeam/blob/master/CHANGELOG.md)). I did not test an addon.

### 3.5 Prior art for D3

| Project               | Engine and boundary                                | Status and lesson                                                                                                                                                                                                                                                                                                                            |
| --------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| erlang_js (Basho)     | SpiderMonkey 1.8.0 in a linked-in driver           | Built for Riak MapReduce ([README](https://github.com/basho/erlang_js)). Riak docs say "Javascript MapReduce is deprecated and will be removed in a future version" ([Riak KV 2.2.0](https://docs.riak.com/riak/kv/2.2.0/developing/app-guide/advanced-mapreduce/)). Archived; last push 2021-11-18. Unverified: no stated technical reason. |
| erlv8 and BeamJS      | V8 in a NIF, one OS thread per VM                  | `erlv8.cc` calls `v8::Locker::StartPreemption(preemption)` ([source](https://github.com/beamjs/erlv8/blob/master/c_src/erlv8.cc)). V8 removed the preemption thread and API in r17967 on 2013-11-21 ([review 62283010](https://codereview.chromium.org/62283010/)). Last push 2012-11-30.                                                    |
| erlang_v8             | V8 in an external OS process                       | Last push 2021-11-01 ([repository](https://github.com/strange/erlang_v8)).                                                                                                                                                                                                                                                                   |
| execjs (Elixir)       | An external runtime such as Node.js                | Last push 2018-08-13 ([README](https://github.com/devinus/execjs)).                                                                                                                                                                                                                                                                          |
| elixir-nodejs         | A supervised pool of Node.js processes             | Last push 2026-03-23 ([README](https://github.com/revelrylabs/elixir-nodejs)).                                                                                                                                                                                                                                                               |
| Denox                 | V8 through `deno_runtime`, Rustler, dirty CPU NIFs | One OS thread per runtime and a round-robin pool of isolates ([README](https://readme.hex.pm/denox/0.9.0)). The first build compiles V8 from source in "~20-30 minutes".                                                                                                                                                                     |
| QuickBEAM             | QuickJS-NG in Zig NIFs on worker threads           | Created 2026-03-10; 0.11.3 released 2026-10-07 (GitHub API). Web APIs over OTP, Node-API, an OXC TypeScript toolchain, and a BEAM interpreter tier. Measured in 3.2 and 3.4.                                                                                                                                                                 |
| Quicksand, MquickjsEx | QuickJS-NG or MQuickJS behind NIFs with limits     | Sandboxes for small scripts. MQuickJS implements "a subset of JavaScript close to ES5" ([Elixir Forum](https://elixirforum.com/t/mquickjsex-embed-javascript-in-elixir-without-node-js/73798), [hex](https://hex.pm/packages/quicksand)).                                                                                                    |

Lessons from the prior art:

- erlv8 relied on `StartPreemption`, which V8 removed in 2013. Its last commit came in 2012. An engine embedded through a NIF ties the host to the engine's API changes.
- Current projects keep JavaScript off the normal schedulers. Denox uses dirty schedulers and QuickBEAM uses its own threads.
- None of the current projects preempts JavaScript and resumes it later. They stop scripts with timeouts or opcode budgets.

## Part 4. Scores

Scale: 5 is the best that the evidence supports among the options in this note. 3 is workable with known costs. 1 blocks the goal or comes close. Option D3 has two variants with different profiles, so each gets its own column. Option C appears only where BEAM evidence applies.

| Criterion                             | A   | D3, QuickJS in NIF threads | D3, Node.js behind ports | C (BEAM evidence only) |
| ------------------------------------- | --- | -------------------------- | ------------------------ | ---------------------- |
| TypeScript and npm compatibility      | 1   | 3                          | 5                        | not scored             |
| Runtime isolation and fault tolerance | 5   | 3                          | 4                        | 2                      |
| Scheduling fairness                   | 5   | 2                          | 3                        | 3                      |
| Startup time and memory per actor     | 3   | 2                          | 1                        | 5                      |
| Message throughput and latency        | 3   | 2                          | 2                        | 5                      |
| I/O and streaming performance         | 2   | 3                          | 4                        | not scored             |
| Implementation complexity             | 1   | 3                          | 3                        | not scored             |
| Debuggability and tooling             | 2   | 2                          | 3                        | not scored             |
| Long-term extensibility               | 2   | 3                          | 3                        | not scored             |

### Option A

- **TypeScript and npm compatibility, 1.** Bouy would reimplement JavaScript semantics (2.1) and web APIs, and Node-API addons could never load. The one running JavaScript-on-BEAM interpreter fails on zod (2.4).
- **Runtime isolation and fault tolerance, 5.** Each actor is a BEAM process with its own heap, a heap limit with kill, links, monitors, and supervisors (1.2, 1.7, 1.8). No native engine shares the VM.
- **Scheduling fairness, 5.** Compiled code counts reductions at every call, so preemption needs no extra work (1.3). The emulated heap adds function calls, and each of them counts too.
- **Startup time and memory per actor, 3.** A process costs 2,632 bytes and about 1 µs (1.1). Unverified: the mutable module state of loaded npm packages must exist in each actor's heap. A prototype that loads zod and ai into one actor would measure it.
- **Message throughput and latency, 3.** BEAM delivers a round trip in 0.5 µs (1.5). Each object that crosses actors must leave the sender's emulated heap as a term and enter the receiver's heap, a deep copy at each end. That cost is unmeasured.
- **I/O and streaming performance, 2.** BEAM sockets and files are mature, but stream code from npm runs on the emulated heap. That code cost 13 to 16 times V8 when compiled by hand, and 112 to 155 times native QuickJS when interpreted (2.2).
- **Implementation complexity, 1.** The work is a JavaScript engine written as a compiler: semantics, a collector, web APIs, and Node APIs. The JavaScript-on-BEAM projects in 2.4 are bounded or stalled, and Fable's target for a mutating language is alpha.
- **Debuggability and tooling, 2.** BEAM tools see processes and support `perf` (1.12). JavaScript stack traces, breakpoints, and source maps over BEAM code would all be new work. TypeScript editors and `tsc` still work.
- **Long-term extensibility, 2.** OTP brings distribution, hot code loading, and supervision. Each ECMAScript edition and each new web API is Bouy's work. npm code also uses V8 hooks such as `Error.captureStackTrace` (zod) and `Error.prepareStackTrace` (provider-utils).

### Option D3, QuickJS in NIF threads (QuickBEAM design)

- **TypeScript and npm compatibility, 3.** zod passed 4 of 4 and ai passed 3 of 4 (3.4). Web APIs are reimplemented and have gaps such as `pull()` streams. Node-API exists, and I did not test it.
- **Runtime isolation and fault tolerance, 3.** JavaScript errors stay inside the context, and limits stop runaway scripts (3.2). A memory fault in the C engine or the NIF glue still ends the VM (1.4). Contexts on one thread share its fate.
- **Scheduling fairness, 2.** The BEAM schedulers stay fair (3.2). Contexts on one thread wait for each other, up to the timeout. Fairness between actors needs one OS thread per runtime.
- **Startup time and memory per actor, 2.** A bare context costs 274 µs to 345 µs and about 319 KiB, about 124 times an idle BEAM process (3.2, 1.1).
- **Message throughput and latency, 2.** A call costs 13 µs to 36 µs at the median, 25 to 73 times a BEAM round trip, and every value is converted at the boundary (3.2).
- **I/O and streaming performance, 3.** BEAM clients do the I/O. Each crossing of the NIF boundary cost 10 µs to 24 µs in the `Beam.callSync` test (3.2). Unverified: real SSE streaming through QuickBEAM `fetch` was not tested.
- **Implementation complexity, 3.** QuickBEAM exists under MIT and is active. Building on it means owning a Zig and C NIF stack, an Elixir runtime, and polyfills. Building the same stack from scratch would score 2.
- **Debuggability and tooling, 2.** Two runtimes must be debugged together. Unverified: I found no Chrome DevTools Protocol support in QuickJS-NG. A search of the QuickJS-NG source and docs for a debugger interface would settle it.
- **Long-term extensibility, 3.** OTP features apply to the host side. QuickJS has no JIT, and native QuickJS ran `fib(27)` about 10 times slower than V8 with JIT ([measurements-beam-quickjs.md](measurements-beam-quickjs.md), 14.03 ms against 1.38 ms). Denox shows that V8 can replace QuickJS behind the same kind of boundary.

### Option D3, Node.js behind ports

- **TypeScript and npm compatibility, 5.** Each port runs real Node.js, so npm and Node-API work.
- **Runtime isolation and fault tolerance, 4.** A crash ends one OS process, and the BEAM sees an exit status (1.4). Actors inside one pooled Node.js process share its fate.
- **Scheduling fairness, 3.** The OS schedules the processes, and the BEAM schedulers stay free. Inside one Node.js process, each job runs to completion before the next one starts.
- **Startup time and memory per actor, 1.** One process per actor costs 10 ms to 35 ms and about 40 MiB (3.3).
- **Message throughput and latency, 2.** A 16-byte round trip costs 4.5 µs to 6.7 µs at the median, plus serialization, which I did not measure (3.3).
- **I/O and streaming performance, 4.** Node.js does its own I/O natively. Only results cross the port.
- **Implementation complexity, 3.** The bridge is small, and elixir-nodejs shows the pattern. The actor model is split across two runtimes with two toolchains.
- **Debuggability and tooling, 3.** The Node.js inspector works in each process, and BEAM tools watch the supervisors. Tracing a request across both is manual.
- **Long-term extensibility, 3.** Node.js improvements arrive for free, and OTP distribution is available. Two runtimes remain permanent.

### Option C, where BEAM evidence applies

- **Runtime isolation and fault tolerance, 2.** BEAM isolates actors with separate heaps, a heap limit with kill, and `exit_signal(Pid, kill)` at any point (1.2, 1.7). Actors in one isolate share one heap and all npm module state ([actor-models.md](actor-models.md), finding 9). V8 can terminate only the isolate's current execution (3.2).
- **Scheduling fairness, 3.** A job runs to completion within an agent (2.1), and V8 interrupts cannot run other JavaScript in the isolate (3.2). Preemption needs yield checks inserted by the compiler. [measurements-node.md](measurements-node.md) E5 measured 0.57 ns to 0.91 ns per iteration for a counter check, and 0.20 ns for an index mask. Native code such as `JSON.parse` stays unpreemptible.
- **Startup time and memory per actor, 5.** An async-function actor uses 752 bytes of V8 heap and spawns in 0.4 µs to 0.5 µs, against 2,632 bytes and 1.2 µs to 1.5 µs for a BEAM process ([measurements-beam-quickjs.md](measurements-beam-quickjs.md)).
- **Message throughput and latency, 5.** An in-isolate round trip passes a reference in 0.11 µs to 0.16 µs, against 0.5 µs for BEAM ([measurements-beam-quickjs.md](measurements-beam-quickjs.md)). The isolate passes a reference without a copy. BEAM copies the message, which is the price of its isolation.

## Implications for Bouy

### Semantics to copy from OTP

1. **Ordering.** Guarantee FIFO per sender and receiver pair, and nothing stronger. Document that arrival time is unspecified and that messages to a remote actor can be lost when the link fails (1.5).
2. **Supervision.** Offer `one_for_one` (default), `one_for_all`, `rest_for_one`, and a dynamic `simple_one_for_one` form. Use `intensity` 1 and `period` 5 s as defaults, and document that nested supervisors multiply their intensities (1.8).
3. **Restart types.** Copy `permanent` (default), `transient` (restart unless the reason is `normal`, `shutdown`, or `{shutdown, _}`), and `temporary`. Copy `significant` children with `auto_shutdown` (1.8).
4. **Shutdown.** Stop children in reverse start order. Give a worker 5,000 ms to stop before a kill, and give a supervisor unlimited time (1.8).
5. **Call timeouts.** Default to 5,000 ms. Fail the caller with a typed timeout, and drop late replies as process aliases do. OTP does not tell the callee, so Bouy should also pass an `AbortSignal` to the callee, because the AI SDK accepts one (1.9, 2.3).
6. **Replies.** Correlate a reply with an identifier created before the send. Do not offer pattern-based selective receive, which scans the whole mailbox at about 2.6 ns per skipped message (1.6).
7. **Failure signals.** Copy one-way monitors with an immediate `noproc` result, and two-way links with an opt-in trap. Copy an untrappable kill (1.7).
8. **Memory limits.** Give each actor a memory limit that kills it when exceeded, as `max_heap_size` does (1.2).
9. **Idle actors.** Provide hibernation for actors that wait on slow model calls. BEAM cuts an idle process from 2,632 bytes to 824 bytes (1.1).
10. **Hot mailboxes.** Let many senders enqueue in parallel. With 16 senders, OTP's `off_heap` buffers gave 16.7 to 20.7 million messages per second, against 1.8 to 2.3 million with `on_heap` (1.5).
11. **Control messages.** Let cancellation and exit signals skip the queue, as OTP 28 priority messages do, and keep that path rare (1.5).
12. **Preemption budget.** Count a budget at calls and loop back-edges, and switch actors when it runs out. OTP uses 4,000 reductions (1.3).

### What a JavaScript engine cannot copy

1. **Preemption inside a job.** ECMAScript runs each job to completion within an agent (2.1). V8 interrupts cannot run other JavaScript in the isolate, and QuickJS can only abort (3.2). Bouy can switch actors only at points that its compiler inserts. A long `JSON.parse`, a regular expression, or a synchronous native addon call cannot be preempted.
2. **Per-actor garbage collection.** One isolate has one heap and one collector. An actor's memory limit inside an isolate needs a separate isolate or accounting by Bouy. BEAM gets both from per-process heaps (1.2).
3. **Isolation by copying.** BEAM copies each message into the receiver's heap, and its terms cannot change after they are built (1.2). In one isolate, a message passes a reference to a mutable object, so Bouy must copy or freeze values at the boundary.
4. **Kill at any point.** `exit_signal(Pid, kill)` ends a BEAM process wherever it runs and frees its heap (1.7). In a shared isolate, a watchdog can only end the current execution with `TerminateExecution` (3.2). The actor's objects stay in the shared heap until the collector finds them unreachable. Inference: any module state that the actor was changing stays half-written.
5. **Two code versions per module.** BEAM keeps current and old code, and a qualified call moves a process forward (1.11). Inference: a loaded JavaScript module instance has no in-place replacement, and closures keep their old code. Bouy can change behavior by restarting an actor with a new version.
6. **Location-transparent pids.** BEAM sends to a remote pid with the same syntax (1.10). Bouy must build its own transport and its own rules for failure across machines.
7. **Engines inside a BEAM host.** If Bouy embeds an engine in a BEAM host anyway (option D3), it must never run JavaScript on a normal scheduler (1.4). A native fault there still ends the whole VM.

## Unverified points

- Per-actor memory under option A when zod and ai are loaded. A TS-to-BEAM prototype, or `QuickBEAM.VM` after it supports `BigInt`, would measure it.
- The cost of moving JavaScript objects between emulated heaps in option A. A prototype with deep objects of known size would measure it.
- The cause of the 9.8 ms to 14.6 ms baseline maximums and the 54 ms to 70 ms dirty-NIF maximums in A.4. Tracing garbage collection of the probe process with `erlang:trace` would show whether the growing sample list causes them.
- Whether the `pull()` stream defect breaks real streaming through QuickBEAM `fetch`. Streaming from a local SSE server through QuickBEAM would show it.
- Whether a QuickJS-NG memory fault inside QuickBEAM ends the VM. The `erl_nif` rule predicts it. A known crashing input would confirm it.
- The measured `setTimeout(r, 0)` inside QuickBEAM resolved in 8 ms including the eval. Timing many timers in one eval would separate timer latency from call overhead.
- Serialization cost for structured messages through a port. A JSON round trip of the probe's messages would measure it.
- Distribution latency and ordering across a reconnect. A two-node test that drops the connection would show both.
- The reasons that Lumen/Firefly, ElixirScript, Caramel, and erlang_js stopped. Statements from their maintainers would settle them. The Firefly reason above comes from a newsletter.
- The scope and last activity of erlyjs and of the 2007 ActionScript compiler. Their source repositories would settle both.

## Sources

Erlang/OTP documentation (OTP 29.1.2 pages, read 2026-10-16):

- Efficiency guide, processes: https://www.erlang.org/doc/system/eff_guide_processes.html
- Garbage collector: https://www.erlang.org/doc/apps/erts/garbagecollection.html
- Processes reference manual: https://www.erlang.org/doc/system/ref_man_processes.html
- `erlang` module: https://www.erlang.org/doc/apps/erts/erlang.html
- `erl_nif`: https://www.erlang.org/doc/apps/erts/erl_nif.html
- `erl` flags: https://www.erlang.org/doc/apps/erts/erl_cmd.html
- System limits: https://www.erlang.org/doc/system/system_limits.html
- Ports: https://www.erlang.org/doc/system/ports.html
- `supervisor`: https://www.erlang.org/doc/apps/stdlib/supervisor.html
- Supervision principles: https://www.erlang.org/doc/system/sup_princ.html
- `gen_server`: https://www.erlang.org/doc/apps/stdlib/gen_server.html
- Distributed Erlang: https://www.erlang.org/doc/system/distributed.html
- `global`: https://www.erlang.org/doc/apps/kernel/global.html
- Kernel application (`net_ticktime`): https://www.erlang.org/doc/apps/kernel/kernel_app.html
- Code loading: https://www.erlang.org/doc/system/code_loading.html
- Release handling: https://www.erlang.org/doc/system/release_handling.html
- BeamAsm: https://www.erlang.org/doc/apps/erts/beamasm.html
- Data types (floats): https://www.erlang.org/doc/system/data_types.html
- `maps`: https://www.erlang.org/doc/apps/stdlib/maps.html
- `ets`: https://www.erlang.org/doc/apps/stdlib/ets.html
- `atomics`: https://www.erlang.org/doc/apps/erts/atomics.html
- `erl_vm.h` (`CONTEXT_REDS`): https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_vm.h

Erlang/OTP announcements and posts:

- A first look at the JIT (2020-11-03): https://www.erlang.org/blog/a-first-look-at-the-jit/
- OTP 24.0 (2021-05-12): https://www.erlang.org/news/148
- OTP 25.0 (2022-05-18): https://erlang.org/news/157
- The many-to-one parallel signal sending optimization (2021-11-05): https://www.erlang.org/blog/parallel-signal-sending-optimization/

JavaScript and engines:

- ECMAScript 2027 draft, jobs and agents: https://tc39.es/ecma262/multipage/executable-code-and-execution-contexts.html
- ECMAScript 2027 draft, data types: https://tc39.es/ecma262/multipage/ecmascript-data-types-and-values.html
- Node-API (v26.12.0 docs): https://nodejs.org/api/n-api.html
- V8 `v8-isolate.h`: https://chromium.googlesource.com/v8/v8/+/refs/heads/main/include/v8-isolate.h
- V8 review 62283010, "Remove preemption thread and API": https://codereview.chromium.org/62283010/
- QuickJS documentation: https://bellard.org/quickjs/quickjs.html
- QuickJS-NG `quickjs.c`: https://github.com/quickjs-ng/quickjs/blob/master/quickjs.c
- zod source: https://github.com/colinhacks/zod
- Vercel AI SDK source: https://github.com/vercel/ai

Prior art:

- QuickBEAM README, AGENTS.md, CHANGELOG, and VM sources: https://github.com/elixir-volt/quickbeam
- Luerl: https://github.com/rvirding/luerl
- Fable BEAM compatibility: https://fable.io/docs/beam/compatibility.html
- Fable BEAM features: https://fable.io/docs/beam/features.html
- purerl: https://github.com/purerl/purerl
- Caramel: https://github.com/leostera/caramel
- Firefly: https://github.com/GetFirefly/firefly
- Underjord newsletter 105: https://underjord.io/newsletters/underjord/underjord-newsletter-105.html
- Gleam externals: https://gleam.run/documentation/externals/
- `gleam_erlang` `process.gleam`: https://github.com/gleam-lang/erlang/blob/main/src/gleam/erlang/process.gleam
- ElixirScript: https://github.com/elixirscript/elixirscript
- Elixir Forum, "How is Firefly going?": https://elixirforum.com/t/how-is-firefly-going/58134
- Popcorn: https://github.com/software-mansion/popcorn
- erlang-questions, 2007-10 (ActionScript to Erlang): https://erlang.org/pipermail/erlang-questions/2007-October/029979.html
- erlang-questions, 2012-06 (erlyjs): https://erlang.org/pipermail/erlang-questions/2012-June/067597.html
- erlang_js: https://github.com/basho/erlang_js
- Riak KV 2.2.0 advanced MapReduce: https://docs.riak.com/riak/kv/2.2.0/developing/app-guide/advanced-mapreduce/
- erlv8: https://github.com/beamjs/erlv8
- erlang_v8: https://github.com/strange/erlang_v8
- execjs: https://github.com/devinus/execjs
- elixir-nodejs: https://github.com/revelrylabs/elixir-nodejs
- Denox 0.9.0 README: https://readme.hex.pm/denox/0.9.0
- Quicksand: https://hex.pm/packages/quicksand
- MquickjsEx: https://elixirforum.com/t/mquickjsex-embed-javascript-in-elixir-without-node-js/73798
- Rustler: https://github.com/rusterlium/rustler

Other Bouy research notes:

- [measurements-beam-quickjs.md](measurements-beam-quickjs.md)
- [measurements-node.md](measurements-node.md)
- [actor-models.md](actor-models.md)

## Appendix A: scripts and commands

All scripts live in `/tmp/bouy-beam-bench/`, outside the repository. Each command ran from the host shell. `erlang:latest` resolved to OTP 29.1.2 and `elixir:latest` to Elixir 1.20.4 on OTP 29 on 2026-10-16.

### A.1 Spawn cost and memory per process

Command, for N in 10000, 100000, and 1000000, MODE in `plain` and `hibernate`, three times each:

```sh
docker run --rm -v /tmp/bouy-beam-bench/erlang:/w -w /w erlang:latest \
  sh -c "erlc bb_spawn.erl && erl +P 4000000 -noshell -s bb_spawn main $N $MODE"
```

`/tmp/bouy-beam-bench/erlang/bb_spawn.erl`

```erlang
%% Spawn cost and memory per idle process. Run one size per fresh VM.
-module(bb_spawn).
-export([main/1, idle/0, idle_hibernate/0]).

main([NStr, ModeStr]) ->
    N = list_to_integer(atom_to_list(NStr)),
    Mode = ModeStr,
    Fun = idle_fun(Mode),
    erlang:garbage_collect(),
    Mem0 = erlang:memory(processes_used),
    Count0 = erlang:system_info(process_count),
    T0 = erlang:monotonic_time(nanosecond),
    spawn_n(N, Fun),
    T1 = erlang:monotonic_time(nanosecond),
    settle(Count0 + N),
    erlang:garbage_collect(),
    Mem1 = erlang:memory(processes_used),
    Sample = spawn(fun() -> (Fun)() end),
    timer:sleep(50),
    {memory, SampleBytes} = erlang:process_info(Sample, memory),
    {total_heap_size, SampleHeapWords} = erlang:process_info(Sample, total_heap_size),
    io:format("mode=~p n=~p spawn_ns_per_process=~.1f processes_used_bytes_per_process=~.1f "
              "sample_process_info_memory_bytes=~p sample_total_heap_words=~p wordsize=~p otp=~s~n",
              [Mode, N, (T1 - T0) / N, (Mem1 - Mem0) / N, SampleBytes, SampleHeapWords,
               erlang:system_info(wordsize), erlang:system_info(otp_release)]),
    halt(0).

idle_fun(plain) -> fun ?MODULE:idle/0;
idle_fun(hibernate) -> fun ?MODULE:idle_hibernate/0.

idle() -> receive stop -> ok end.
idle_hibernate() -> erlang:hibernate(?MODULE, idle, []).

spawn_n(0, _Fun) -> ok;
spawn_n(N, Fun) -> spawn(Fun), spawn_n(N - 1, Fun).

settle(Target) ->
    case erlang:system_info(process_count) >= Target of
        true -> timer:sleep(200);
        false -> timer:sleep(10), settle(Target)
    end.
```

### A.2 Round trips, `gen_server:call`, and throughput

Commands, three times each:

```sh
docker run --rm -v /tmp/bouy-beam-bench/erlang:/w -w /w erlang:latest sh -c 'erlc bb_msg.erl && \
  erl +S 1 -noshell -s bb_msg main pingpong; erl +S 1 -noshell -s bb_msg main gen_call; \
  erl -noshell -s bb_msg main pingpong; erl -noshell -s bb_msg main gen_call; \
  erl -noshell -s bb_msg main throughput; erl -noshell -s bb_msg main throughput_off_heap'
```

`/tmp/bouy-beam-bench/erlang/bb_msg.erl`

```erlang
%% Message latency, gen_server call latency, and throughput.
-module(bb_msg).
-behaviour(gen_server).
-export([main/1, init/1, handle_call/3, handle_cast/2]).

now_ns() -> erlang:monotonic_time(nanosecond).

main([Which]) ->
    run(Which),
    halt(0).

run(pingpong) ->
    N = 1000000,
    Pong = spawn(fun pong/0),
    ping(10000, Pong),
    T0 = now_ns(), ping(N, Pong), T1 = now_ns(),
    Pong ! stop,
    Lat = pingpong_hist(100000),
    io:format("pingpong schedulers=~p round_trips=~p mean_ns=~.1f ~s~n",
              [erlang:system_info(schedulers_online), N, (T1 - T0) / N, Lat]);
run(gen_call) ->
    N = 1000000,
    {ok, S} = gen_server:start(?MODULE, [], []),
    call_n(10000, S),
    T0 = now_ns(), call_n(N, S), T1 = now_ns(),
    io:format("gen_server_call schedulers=~p calls=~p mean_ns=~.1f~n",
              [erlang:system_info(schedulers_online), N, (T1 - T0) / N]);
run(throughput) -> throughput_all(on_heap);
run(throughput_off_heap) -> throughput_all(off_heap).

throughput_all(Mqd) ->
    Small = 42,
    Tuple = list_to_tuple(lists:seq(1, 100)),
    Bin = binary:copy(<<"x">>, 1024),
    [throughput(Mqd, Label, Msg, Senders, PerSender)
     || {Label, Msg} <- [{small_int, Small}, {tuple_100_ints, Tuple}, {binary_1kib_refc, Bin}],
        {Senders, PerSender} <- [{1, 2000000}, {16, 250000}]].

pong() ->
    receive
        {From, ping} -> From ! pong, pong();
        stop -> ok
    end.

ping(0, _) -> ok;
ping(K, Pong) ->
    Pong ! {self(), ping},
    receive pong -> ping(K - 1, Pong) end.

pingpong_hist(N) ->
    Pong = spawn(fun pong/0),
    Samples = [begin
                   T0 = now_ns(),
                   Pong ! {self(), ping},
                   receive pong -> ok end,
                   now_ns() - T0
               end || _ <- lists:seq(1, N)],
    Pong ! stop,
    percentiles(Samples).

percentiles(Samples) ->
    Sorted = lists:sort(Samples),
    Len = length(Sorted),
    P = fun(Q) -> lists:nth(max(1, round(Q * Len)), Sorted) end,
    io_lib:format("p50_ns=~p p99_ns=~p p999_ns=~p max_ns=~p", [P(0.5), P(0.99), P(0.999), lists:last(Sorted)]).

call_n(0, _) -> ok;
call_n(K, S) -> ping = gen_server:call(S, ping), call_n(K - 1, S).

init([]) -> {ok, nostate}.
handle_call(ping, _From, State) -> {reply, ping, State}.
handle_cast(_, State) -> {noreply, State}.

throughput(Mqd, Label, Msg, Senders, PerSender) ->
    Total = Senders * PerSender,
    Parent = self(),
    Sink = spawn_opt(fun() -> sink(Total, Parent) end, [{message_queue_data, Mqd}]),
    Go = make_ref(),
    Pids = [spawn(fun() -> receive Go -> send_n(PerSender, Sink, Msg) end end)
            || _ <- lists:seq(1, Senders)],
    T0 = now_ns(),
    [P ! Go || P <- Pids],
    receive {done, Sink} -> ok end,
    T1 = now_ns(),
    Secs = (T1 - T0) / 1.0e9,
    io:format("throughput schedulers=~p sink_message_queue_data=~p payload=~p senders=~p messages=~p msgs_per_sec=~p ns_per_msg=~.1f~n",
              [erlang:system_info(schedulers_online), Mqd, Label, Senders, Total, round(Total / Secs),
               (T1 - T0) / Total]).

send_n(0, _, _) -> ok;
send_n(K, Sink, Msg) -> Sink ! Msg, send_n(K - 1, Sink, Msg).

sink(0, Parent) -> Parent ! {done, self()};
sink(K, Parent) -> receive _ -> sink(K - 1, Parent) end.
```

### A.3 Reductions per slice and latency next to a CPU-bound process

Command, three times:

```sh
docker run --rm -v /tmp/bouy-beam-bench/erlang:/w -w /w erlang:latest sh -c 'erlc bb_sched.erl && \
  erl +S 1 -noshell -s bb_sched main slice; erl +S 1 -noshell -s bb_sched main latency'
```

`/tmp/bouy-beam-bench/erlang/bb_sched.erl`

```erlang
%% Reduction-based preemption: reductions and wall time per slice, and
%% message latency while a CPU-bound process shares the only scheduler.
-module(bb_sched).
-export([main/1, hog/0, map_hog/1]).

now_ns() -> erlang:monotonic_time(nanosecond).

main([slice]) ->
    slice(fun ?MODULE:hog/0, call_loop),
    slice(fun() -> ?MODULE:map_hog(#{}) end, map_update_loop),
    halt(0);
main([latency]) ->
    io:format("baseline ~s~n", [probe(20000)]),
    Hog = spawn(fun ?MODULE:hog/0),
    io:format("with_cpu_hog ~s~n", [probe(20000)]),
    exit(Hog, kill),
    halt(0).

hog() -> hog().
map_hog(M) -> map_hog(M#{a => erlang:unique_integer()}).

slice(HogFun, Label) ->
    Hog = spawn(HogFun),
    erlang:yield(),
    Samples = sample(Hog, 2000, []),
    exit(Hog, kill),
    Pairs = lists:zip(lists:droplast(Samples), tl(Samples)),
    Reds = lists:sort([R2 - R1 || {{R1, _}, {R2, _}} <- Pairs]),
    Times = lists:sort([T2 - T1 || {{_, T1}, {_, T2}} <- Pairs]),
    Med = fun(L) -> lists:nth(length(L) div 2, L) end,
    io:format("slice workload=~p schedulers=~p samples=~p reductions_per_slice_median=~p min=~p max=~p "
              "ns_per_round_median=~p~n",
              [Label, erlang:system_info(schedulers_online), length(Reds), Med(Reds), hd(Reds),
               lists:last(Reds), Med(Times)]).

sample(_, 0, Acc) -> lists:reverse(Acc);
sample(Hog, K, Acc) ->
    {reductions, R} = erlang:process_info(Hog, reductions),
    T = now_ns(),
    erlang:yield(),
    sample(Hog, K - 1, [{R, T} | Acc]).

probe(N) ->
    Pong = spawn(fun pong/0),
    Samples = [begin
                   T0 = now_ns(),
                   Pong ! {self(), ping},
                   receive pong -> ok end,
                   now_ns() - T0
               end || _ <- lists:seq(1, N)],
    Pong ! stop,
    Sorted = lists:sort(Samples),
    Len = length(Sorted),
    P = fun(Q) -> lists:nth(max(1, round(Q * Len)), Sorted) end,
    io_lib:format("schedulers=~p round_trips=~p p50_ns=~p p99_ns=~p max_ns=~p",
                  [erlang:system_info(schedulers_online), N, P(0.5), P(0.99), lists:last(Sorted)]).

pong() ->
    receive
        {From, ping} -> From ! pong, pong();
        stop -> ok
    end.
```

### A.4 NIF on a normal scheduler, NIF on a dirty scheduler, and crash isolation

Command. The `latency` run was repeated three times. An earlier version of `work/1` had no `erlang:yield()`. That run held the scheduler for more than 300 s, and I stopped its container with `docker kill`.

```sh
docker run --rm -v /tmp/bouy-beam-bench/nif:/w -w /w erlang:latest sh -c '\
  gcc -O2 -fPIC -shared -I/usr/local/lib/erlang/usr/include -o bb_nif.so bb_nif.c && erlc bb_nif.erl && \
  erl -noshell -s bb_nif main reductions && \
  erl +S 1 +SDcpu 1 -noshell -s bb_nif main latency; \
  erl +S 1 +SDcpu 1 -noshell -s bb_nif main crash; echo "vm_exit_code=$?"; \
  erl -noshell -s bb_nif main port_crash; echo "vm_exit_code=$?"'
```

`/tmp/bouy-beam-bench/nif/bb_nif.c`

```c
/* Busy-wait NIFs: one on a normal scheduler, one on a dirty CPU scheduler, and one that crashes. */
#include <erl_nif.h>
#include <time.h>

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static ERL_NIF_TERM spin(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int ms;
    if (!enif_get_int(env, argv[0], &ms)) return enif_make_badarg(env);
    long long end = now_ms() + ms;
    volatile unsigned long x = 0;
    while (now_ms() < end) x++;
    return enif_make_atom(env, "ok");
}

static ERL_NIF_TERM crash(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    volatile int* p = (int*)0;
    *p = 1;
    return enif_make_atom(env, "unreachable");
}

static ErlNifFunc funcs[] = {
    {"spin", 1, spin, 0},
    {"spin_dirty", 1, spin, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"crash", 0, crash, 0},
};

ERL_NIF_INIT(bb_nif, funcs, NULL, NULL, NULL, NULL)
```

`/tmp/bouy-beam-bench/nif/bb_nif.erl`

```erlang
%% Effect of a long NIF on message latency when the NIF runs on a normal vs a dirty scheduler.
-module(bb_nif).
-export([main/1, spin/1, spin_dirty/1, crash/0]).
-nifs([spin/1, spin_dirty/1, crash/0]).
-on_load(init/0).

init() -> erlang:load_nif("./bb_nif", 0).
spin(_) -> erlang:nif_error(not_loaded).
spin_dirty(_) -> erlang:nif_error(not_loaded).
crash() -> erlang:nif_error(not_loaded).

now_ns() -> erlang:monotonic_time(nanosecond).

main([reductions]) ->
    {reductions, R0} = process_info(self(), reductions),
    [spin(0) || _ <- lists:seq(1, 1000)],
    {reductions, R1} = process_info(self(), reductions),
    io:format("reductions_per_1000_normal_nif_calls=~p (includes the list comprehension)~n", [R1 - R0]),
    halt(0);
main([latency]) ->
    [run(Kind) || Kind <- [none, spin, spin_dirty]],
    halt(0);
main([crash]) ->
    io:format("calling a NIF that dereferences NULL~n"),
    try crash() catch _:_ -> ok end,
    io:format("not reached~n"),
    halt(0);
main([port_crash]) ->
    Port = open_port({spawn, "sh -c 'kill -SEGV $$'"}, [exit_status]),
    receive
        {Port, {exit_status, S}} -> io:format("port program crashed, VM alive, exit_status=~p~n", [S])
    after 5000 -> io:format("no exit status~n")
    end,
    halt(0).

run(Kind) ->
    Worker = spawn(fun() -> work(Kind) end),
    timer:sleep(20),
    Pong = spawn(fun pong/0),
    Deadline = now_ns() + 2000000000,
    Samples = probe(Pong, Deadline, []),
    exit(Worker, kill),
    Pong ! stop,
    Sorted = lists:sort(Samples),
    Len = length(Sorted),
    P = fun(Q) -> lists:nth(max(1, round(Q * Len)), Sorted) end,
    io:format("nif=~p schedulers=~p dirty_cpu=~p probes_in_2s=~p p50_us=~.1f p99_us=~.1f max_us=~.1f~n",
              [Kind, erlang:system_info(schedulers_online), erlang:system_info(dirty_cpu_schedulers_online),
               Len, P(0.5) / 1000, P(0.99) / 1000, lists:last(Sorted) / 1000]).

probe(Pong, Deadline, Acc) ->
    T0 = now_ns(),
    case T0 > Deadline of
        true -> Acc;
        false ->
            Pong ! {self(), ping},
            receive pong -> ok end,
            probe(Pong, Deadline, [now_ns() - T0 | Acc])
    end.

%% The worker yields after each 100 ms NIF call. Without the yield, one process
%% can call the NIF thousands of times before it uses up its reductions.
work(none) -> receive after infinity -> ok end;
work(spin) -> spin(100), erlang:yield(), work(spin);
work(spin_dirty) -> spin_dirty(100), erlang:yield(), work(spin_dirty).

pong() ->
    receive
        {From, ping} -> From ! pong, pong();
        stop -> ok
    end.
```

### A.5 Selective receive

Command:

```sh
docker run --rm -v /tmp/bouy-beam-bench/recv:/w -w /w erlang:latest sh -c \
  'erlc +recv_opt_info bb_recv.erl; for r in 1 2 3; do erl -noshell -s bb_recv main run; done'
```

`/tmp/bouy-beam-bench/recv/bb_recv.erl`

```erlang
%% Selective receive cost with K unmatched messages in the queue, with and without the reference optimization.
-module(bb_recv).
-export([main/1]).

now_ns() -> erlang:monotonic_time(nanosecond).

main([run]) ->
    [measure(K) || K <- [0, 1000, 10000, 100000]],
    halt(0).

measure(K) ->
    Self = self(),
    [Self ! {junk, I} || I <- lists:seq(1, K)],
    Plain = median([plain_receive(Self) || _ <- lists:seq(1, 21)]),
    Opt = median([ref_receive(Self) || _ <- lists:seq(1, 21)]),
    {message_queue_len, Len} = process_info(Self, message_queue_len),
    io:format("selective_receive queued_unmatched=~p tag_match_us=~.2f fresh_ref_match_us=~.2f queue_len_after=~p~n",
              [K, Plain / 1000, Opt / 1000, Len]),
    flush().

plain_receive(Self) ->
    T0 = now_ns(),
    Self ! {target, 1},
    receive {target, _} -> ok end,
    now_ns() - T0.

ref_receive(Self) ->
    Ref = make_ref(),
    T0 = now_ns(),
    Self ! {Ref, 2},
    receive {Ref, _} -> ok end,
    now_ns() - T0.

median(L) -> lists:nth(length(L) div 2 + 1, lists:sort(L)).

flush() -> receive _ -> flush() after 0 -> ok end.
```

### A.6 Supervisor restart latency

Commands, three times each. The first prints supervisor reports. The second turns logging off.

```sh
docker run --rm -v /tmp/bouy-beam-bench/sup:/w -w /w erlang:latest sh -c 'erlc bb_sup.erl && erl -noshell -s bb_sup main run'
docker run --rm -v /tmp/bouy-beam-bench/sup:/w -w /w erlang:latest sh -c 'erl -noshell -kernel logger_level none -s bb_sup main run'
```

`/tmp/bouy-beam-bench/sup/bb_sup.erl`

```erlang
%% Time from a child crash to its replacement being registered, under a one_for_one supervisor.
-module(bb_sup).
-behaviour(supervisor).
-export([main/1, init/1, start_worker/0, worker_init/1]).

now_ns() -> erlang:monotonic_time(nanosecond).

main([run]) ->
    {ok, Sup} = supervisor:start_link(?MODULE, []),
    N = 10000,
    Samples = [restart_once() || _ <- lists:seq(1, N)],
    Sorted = lists:sort(Samples),
    P = fun(Q) -> lists:nth(max(1, round(Q * N)), Sorted) end,
    io:format("supervisor_restart one_for_one restarts=~p mean_us=~.2f p50_us=~.2f p99_us=~.2f max_us=~.2f~n",
              [N, lists:sum(Samples) / N / 1000, P(0.5) / 1000, P(0.99) / 1000, lists:last(Sorted) / 1000]),
    unlink(Sup),
    halt(0).

restart_once() ->
    Old = whereis(bb_worker),
    T0 = now_ns(),
    exit(Old, kill),
    wait_new(Old),
    now_ns() - T0.

wait_new(Old) ->
    case whereis(bb_worker) of
        Pid when is_pid(Pid), Pid =/= Old -> ok;
        _ -> erlang:yield(), wait_new(Old)
    end.

init([]) ->
    SupFlags = #{strategy => one_for_one, intensity => 1000000, period => 1},
    Child = #{id => worker, start => {?MODULE, start_worker, []}, restart => permanent,
              shutdown => brutal_kill, type => worker},
    {ok, {SupFlags, [Child]}}.

start_worker() -> proc_lib:start_link(?MODULE, worker_init, [self()]).

worker_init(Parent) ->
    register(bb_worker, self()),
    proc_lib:init_ack(Parent, {ok, self()}),
    receive after infinity -> ok end.
```

### A.7 Erlang port to `cat` and to Node.js

Commands. The `node` run was repeated once more.

```sh
cd /tmp/bouy-beam-bench/docker && docker build -q -t bouy-bench-erlang-node -f Dockerfile.erlang-node .
docker run --rm -v /tmp/bouy-beam-bench/port:/w -w /w bouy-bench-erlang-node sh -c \
  'erlc bb_port.erl && erl -noshell -s bb_port main cat && erl -noshell -s bb_port main node'
```

`/tmp/bouy-beam-bench/docker/Dockerfile.erlang-node`

```dockerfile
FROM node:25-trixie AS node
FROM erlang:latest
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/lib/aarch64-linux-gnu/libatomic.so.1* /usr/lib/aarch64-linux-gnu/
```

`/tmp/bouy-beam-bench/port/echo.mjs`

```javascript
// Echo server for an Erlang port opened with {packet, 4}: each frame is a 4-byte big-endian length plus payload.
let pending = Buffer.alloc(0);
process.stdin.on("data", (chunk) => {
  pending = pending.length === 0 ? chunk : Buffer.concat([pending, chunk]);
  const frames = [];
  let offset = 0;
  while (pending.length - offset >= 4) {
    const size = pending.readUInt32BE(offset);
    if (pending.length - offset - 4 < size) break;
    frames.push(pending.subarray(offset, offset + 4 + size));
    offset += 4 + size;
  }
  pending = pending.subarray(offset);
  if (frames.length > 0)
    process.stdout.write(frames.length === 1 ? frames[0] : Buffer.concat(frames));
});
process.stdin.on("end", () => process.exit(0));
```

`/tmp/bouy-beam-bench/port/bb_port.erl`

```erlang
%% Erlang port to an external OS process: startup time, memory, round-trip latency, and throughput.
-module(bb_port).
-export([main/1]).

now_ns() -> erlang:monotonic_time(nanosecond).

main([Prog]) ->
    Cmd = command(Prog),
    startup(Prog, Cmd, 10),
    latency(Prog, Cmd, 100000),
    throughput(Prog, Cmd, 200000),
    halt(0).

command(node) -> "node echo.mjs";
command(cat) -> "cat".

open(Cmd) -> open_port({spawn, Cmd}, [binary, {packet, 4}, exit_status]).

roundtrip(Port, Msg) ->
    port_command(Port, Msg),
    receive {Port, {data, _}} -> ok end.

startup(Prog, Cmd, N) ->
    Results = [begin
                   T0 = now_ns(),
                   Port = open(Cmd),
                   roundtrip(Port, <<"ready?">>),
                   T1 = now_ns(),
                   timer:sleep(300),
                   {os_pid, OsPid} = erlang:port_info(Port, os_pid),
                   Rss = rss_kib(OsPid),
                   port_close(Port),
                   {T1 - T0, Rss}
               end || _ <- lists:seq(1, N)],
    Times = lists:sort([T || {T, _} <- Results]),
    Rsss = lists:sort([R || {_, R} <- Results]),
    io:format("port=~p startup_to_first_echo_ms_median=~.1f min=~.1f max=~.1f rss_kib_median=~p (n=~p)~n",
              [Prog, lists:nth(N div 2, Times) / 1.0e6, hd(Times) / 1.0e6, lists:last(Times) / 1.0e6,
               lists:nth(N div 2, Rsss), N]).

rss_kib(OsPid) ->
    {ok, Bin} = file:read_file("/proc/" ++ integer_to_list(OsPid) ++ "/status"),
    [Line] = [L || L <- binary:split(Bin, <<"\n">>, [global]), binary:match(L, <<"VmRSS:">>) =/= nomatch],
    [_, Kb | _] = binary:split(Line, [<<" ">>, <<"\t">>], [global, trim_all]),
    binary_to_integer(Kb).

latency(Prog, Cmd, N) ->
    Port = open(Cmd),
    Msg = <<"0123456789abcdef">>,
    [roundtrip(Port, Msg) || _ <- lists:seq(1, 1000)],
    Samples = [begin T0 = now_ns(), roundtrip(Port, Msg), now_ns() - T0 end || _ <- lists:seq(1, N)],
    port_close(Port),
    Sorted = lists:sort(Samples),
    P = fun(Q) -> lists:nth(max(1, round(Q * N)), Sorted) end,
    io:format("port=~p round_trips=~p payload_bytes=16 mean_us=~.2f p50_us=~.2f p99_us=~.2f~n",
              [Prog, N, lists:sum(Samples) / N / 1000, P(0.5) / 1000, P(0.99) / 1000]).

throughput(Prog, Cmd, N) ->
    Port = open(Cmd),
    Msg = <<"0123456789abcdef">>,
    roundtrip(Port, Msg),
    Self = self(),
    T0 = now_ns(),
    spawn_link(fun() -> [port_command(Port, Msg) || _ <- lists:seq(1, N)], Self ! sent end),
    receive_n(Port, N),
    T1 = now_ns(),
    receive sent -> ok end,
    port_close(Port),
    io:format("port=~p pipelined_messages=~p payload_bytes=16 msgs_per_sec=~p~n",
              [Prog, N, round(N / ((T1 - T0) / 1.0e9))]).

receive_n(_, 0) -> ok;
receive_n(Port, K) -> receive {Port, {data, _}} -> receive_n(Port, K - 1) end.
```

### A.8 JavaScript-style mutation compiled by hand to Erlang, and the same loop in V8

Command. It ran once with `for r in 1 2 3` and later twice with a single pass, for 5 container runs.

```sh
docker run --rm -v /tmp/bouy-beam-bench/heap:/w -w /w bouy-bench-erlang-node sh -c 'erlc bb_heap.erl && \
  for r in 1 2 3; do erl -noshell -s bb_heap main run; node mutate.mjs jit; node --jitless mutate.mjs jitless; done'
```

`/tmp/bouy-beam-bench/heap/bb_heap.erl`

```erlang
%% Cost of JavaScript-style mutation when hand-compiled to Erlang.
%% JS source: const counter = {hits: 0}; let total = 0; const add = (x) => { total += x };
%%            for (let i = 0; i < n; i++) { counter.hits = counter.hits + 1; add(i & 7); }
%%            return counter.hits + total;
-module(bb_heap).
-export([main/1]).

now_ns() -> erlang:monotonic_time(nanosecond).

main([run]) ->
    N = 1000000,
    [bench(Label, Fun, N) || {Label, Fun} <- [{pure_erlang_no_objects, fun pure/1},
                                              {heap_as_threaded_map, fun threaded/1},
                                              {heap_in_process_dictionary, fun pdict/1},
                                              {heap_in_ets, fun ets_heap/1}]],
    halt(0).

bench(Label, Fun, N) ->
    Fun(N div 10),
    Times = lists:sort([begin T0 = now_ns(), R = Fun(N), {now_ns() - T0, R} end || _ <- lists:seq(1, 5)]),
    {Median, Result} = lists:nth(3, Times),
    io:format("heap_bench variant=~p n=~p median_ms=~.2f ns_per_iteration=~.1f result=~p~n",
              [Label, N, Median / 1.0e6, Median / N, Result]).

%% Baseline: the optimizer view a compiler gets when it proves nothing escapes.
pure(N) -> pure(0, N, 0, 0).
pure(I, N, Hits, Total) when I < N -> pure(I + 1, N, Hits + 1, Total + (I band 7));
pure(_, _, Hits, Total) -> Hits + Total.

%% Objects and boxed closure variables live in a map from id to value, threaded through every call.
threaded(N) ->
    Heap0 = #{1 => #{hits => 0}, 2 => 0},
    Add = fun(X, H) -> #{2 := V} = H, H#{2 := V + X} end,
    threaded(0, N, Add, Heap0).
threaded(I, N, Add, H) when I < N ->
    #{1 := Obj} = H,
    #{hits := Hits} = Obj,
    H1 = H#{1 := Obj#{hits := Hits + 1}},
    threaded(I + 1, N, Add, Add(I band 7, H1));
threaded(_, _, _, H) ->
    #{1 := #{hits := Hits}, 2 := Total} = H,
    Hits + Total.

%% Objects and boxed variables live in the process dictionary (mutable, per process).
pdict(N) ->
    put({obj, 1}, #{hits => 0}),
    put({cell, 2}, 0),
    Add = fun(X) -> put({cell, 2}, get({cell, 2}) + X) end,
    pdict(0, N, Add).
pdict(I, N, Add) when I < N ->
    Obj = get({obj, 1}),
    #{hits := Hits} = Obj,
    put({obj, 1}, Obj#{hits := Hits + 1}),
    Add(I band 7),
    pdict(I + 1, N, Add);
pdict(_, _, _) ->
    #{hits := Hits} = get({obj, 1}),
    Hits + get({cell, 2}).

%% Objects and boxed variables live in an ETS table (shared, copied on every read and write).
ets_heap(N) ->
    T = ets:new(heap, [set, private]),
    ets:insert(T, [{{obj, 1}, #{hits => 0}}, {{cell, 2}, 0}]),
    Add = fun(X) -> ets:update_counter(T, {cell, 2}, X) end,
    R = ets_loop(0, N, T, Add),
    ets:delete(T),
    R.
ets_loop(I, N, T, Add) when I < N ->
    [{_, Obj}] = ets:lookup(T, {obj, 1}),
    #{hits := Hits} = Obj,
    ets:insert(T, {{obj, 1}, Obj#{hits := Hits + 1}}),
    Add(I band 7),
    ets_loop(I + 1, N, T, Add);
ets_loop(_, _, T, _) ->
    [{_, #{hits := Hits}}] = ets:lookup(T, {obj, 1}),
    [{_, Total}] = ets:lookup(T, {cell, 2}),
    Hits + Total.
```

`/tmp/bouy-beam-bench/heap/mutate.mjs`

```javascript
// Same workload in JavaScript, run by V8 (Node) for reference.
function mutate(n) {
  const counter = { hits: 0 };
  let total = 0;
  const add = (x) => {
    total += x;
  };
  for (let i = 0; i < n; i++) {
    counter.hits = counter.hits + 1;
    add(i & 7);
  }
  return counter.hits + total;
}
const n = 1_000_000;
mutate(n / 10);
const times = [];
let result = 0;
for (let k = 0; k < 5; k++) {
  const t0 = process.hrtime.bigint();
  result = mutate(n);
  times.push(Number(process.hrtime.bigint() - t0));
}
times.sort((a, b) => a - b);
console.log(
  `heap_bench variant=v8_${process.argv[2] ?? "jit"} n=${n} median_ms=${(times[2] / 1e6).toFixed(2)} ns_per_iteration=${(times[2] / n).toFixed(1)} result=${result}`,
);
```

### A.9 QuickBEAM 0.11.3

`bench.exs` takes one section name. `runtimes`, `contexts`, and `latency` ran three times. `fairness`, `compat`, and `vm` ran once. The first run also ran `mix local.hex --force`.

```sh
QB='docker run --rm -e MIX_HOME=/cache/mix -e HEX_HOME=/cache/hex -e MIX_INSTALL_DIR=/cache/installs
  -v /tmp/bouy-beam-bench/quickbeam:/b -v /tmp/bouy-beam-bench/compat:/work:ro
  -v /tmp/bouy-beam-bench/quickbeam/cache:/cache -w /b elixir:latest'
for s in runtimes contexts latency fairness compat vm; do $QB sh -c "elixir bench.exs $s"; done
$QB sh -c "elixir diag.exs"
docker run --rm --memory 6g -e MIX_HOME=/cache/mix -e HEX_HOME=/cache/hex -e MIX_INSTALL_DIR=/cache/installs \
  -v /tmp/bouy-beam-bench/quickbeam:/b -v /tmp/bouy-beam-bench/compat:/work:ro \
  -v /tmp/bouy-beam-bench/quickbeam/cache:/cache -w /b elixir:latest sh -c "elixir vmcompat.exs"
```

`vmcompat.exs` first ran with `memory_limit: 2_000_000_000` and the keys `zodParseTransform`, `zodSafeParse`, and `aiGenerateText`. All three returned `{:error, {:limit_exceeded, :memory_bytes, 2000000000}}` after 0.5 s to 0.9 s. The version below raised the limit and kept one key.

`/tmp/bouy-beam-bench/quickbeam/bench.exs`

```elixir
# QuickBEAM (QuickJS-NG in a NIF) measurements for option D3, plus its BEAM-hosted JS interpreter.
Mix.install([{:quickbeam, "0.11.3"}])

defmodule QB do
  def now, do: System.monotonic_time(:nanosecond)

  def rss_kib do
    "/proc/self/status"
    |> File.read!()
    |> String.split("\n")
    |> Enum.find(&String.starts_with?(&1, "VmRSS:"))
    |> String.split()
    |> Enum.at(1)
    |> String.to_integer()
  end

  def threads, do: length(File.ls!("/proc/self/task"))

  def pct(samples, q) do
    sorted = Enum.sort(samples)
    Enum.at(sorted, max(0, round(q * length(sorted)) - 1))
  end

  def report(label, kv), do: IO.puts(label <> " " <> Enum.map_join(kv, " ", fn {k, v} -> "#{k}=#{v}" end))

  def us(ns), do: Float.round(ns / 1000, 2)

  def timed(n, fun) do
    samples = for _ <- 1..n, do: (t0 = now(); fun.(); now() - t0)
    [mean_us: us(Enum.sum(samples) / n), p50_us: us(pct(samples, 0.5)), p99_us: us(pct(samples, 0.99)), max_us: us(Enum.max(samples))]
  end

  def ping_probe(duration_ms) do
    pong = spawn(fn -> pong() end)
    deadline = now() + duration_ms * 1_000_000
    samples = probe(pong, deadline, [])
    send(pong, :stop)
    [probes: length(samples), p99_us: us(pct(samples, 0.99)), max_us: us(Enum.max(samples))]
  end

  defp probe(pong, deadline, acc) do
    t0 = now()
    if t0 > deadline do
      acc
    else
      send(pong, {self(), :ping})
      receive do: (:pong -> :ok)
      probe(pong, deadline, [now() - t0 | acc])
    end
  end

  defp pong do
    receive do
      {from, :ping} -> send(from, :pong); pong()
      :stop -> :ok
    end
  end
end

section = System.argv() |> List.first() |> String.to_atom()

case section do
  :runtimes ->
    for apis <- [false, [:browser]] do
      :erlang.garbage_collect()
      rss0 = QB.rss_kib(); th0 = QB.threads(); t0 = QB.now()
      rts = for _ <- 1..50, do: (({:ok, rt} = QuickBEAM.start(apis: apis)); {:ok, 2} = QuickBEAM.eval(rt, "1 + 1"); rt)
      t1 = QB.now(); Process.sleep(500)
      rss1 = QB.rss_kib(); th1 = QB.threads()
      QB.report("runtime_1to1_thread", apis: inspect(apis), n: 50,
        start_and_first_eval_us: QB.us((t1 - t0) / 50), rss_kib_per_runtime: Float.round((rss1 - rss0) / 50, 1),
        os_threads_per_runtime: (th1 - th0) / 50, memory_usage: inspect(QuickBEAM.memory_usage(hd(rts)), limit: 8))
      Enum.each(rts, &QuickBEAM.stop/1)
    end

  :contexts ->
    {:ok, _} = QuickBEAM.ContextPool.start_link(name: :pool4, size: 4)
    for apis <- [false, [:browser]] do
      :erlang.garbage_collect()
      rss0 = QB.rss_kib(); th0 = QB.threads(); t0 = QB.now()
      ctxs = for _ <- 1..1000, do: (({:ok, c} = QuickBEAM.Context.start_link(pool: :pool4, apis: apis)); c)
      {:ok, 2} = QuickBEAM.Context.eval(List.last(ctxs), "1 + 1")
      t1 = QB.now(); Process.sleep(500)
      rss1 = QB.rss_kib(); th1 = QB.threads()
      QB.report("context_pool4", apis: inspect(apis), n: 1000, create_us: QB.us((t1 - t0) / 1000),
        rss_kib_per_context: Float.round((rss1 - rss0) / 1000, 1), os_threads_added: th1 - th0,
        context_memory_usage: inspect(QuickBEAM.Context.memory_usage(hd(ctxs))))
      Enum.each(ctxs, &GenServer.stop/1)
    end

  :latency ->
    {:ok, rt} = QuickBEAM.start(apis: false)
    QuickBEAM.eval(rt, "function f(o) { return o.a + o.b.length }")
    QB.report("runtime_eval_1_plus_2", QB.timed(20_000, fn -> {:ok, 3} = QuickBEAM.eval(rt, "1 + 2") end))
    QB.report("runtime_call_with_map", QB.timed(20_000, fn -> {:ok, 4} = QuickBEAM.call(rt, "f", [%{"a" => 1, "b" => [1, 2, 3]}]) end))
    {:ok, _} = QuickBEAM.ContextPool.start_link(name: :pool4, size: 4)
    {:ok, ctx} = QuickBEAM.Context.start_link(pool: :pool4, apis: false)
    QB.report("context_eval_1_plus_2", QB.timed(20_000, fn -> {:ok, 3} = QuickBEAM.Context.eval(ctx, "1 + 2") end))
    {:ok, h} = QuickBEAM.start(apis: false, handlers: %{"inc" => fn [x] -> x + 1 end})
    n = 20_000
    t0 = QB.now()
    {:ok, ^n} = QuickBEAM.eval(h, "let x = 0; for (let i = 0; i < #{n}; i++) { x = Beam.callSync('inc', x) } x")
    QB.report("js_to_beam_callSync", calls: n, mean_us: QB.us((QB.now() - t0) / n))

  :fairness ->
    {:ok, _} = QuickBEAM.ContextPool.start_link(name: :pool1, size: 1)
    {:ok, a} = QuickBEAM.Context.start_link(pool: :pool1, apis: false)
    {:ok, b} = QuickBEAM.Context.start_link(pool: :pool1, apis: false)
    QB.report("beam_ping_probe_idle", QB.ping_probe(1000))
    busy = Task.async(fn -> QuickBEAM.Context.eval(a, "let i = 0; for (;;) { i++ }", timeout: 2000) end)
    Process.sleep(100)
    t0 = QB.now()
    {:ok, 2} = QuickBEAM.Context.eval(b, "1 + 1")
    QB.report("same_pool_thread_other_context_eval_while_busy", latency_ms: Float.round((QB.now() - t0) / 1.0e6, 1))
    busy_result = Task.await(busy, 10_000)
    QB.report("busy_context_result", result: inspect(busy_result, limit: 3) |> String.slice(0, 120) |> String.replace(" ", "_"))
    QB.report("busy_context_usable_after_interrupt", result: inspect(QuickBEAM.Context.eval(a, "40 + 2")))
    {:ok, ra} = QuickBEAM.start(apis: false)
    {:ok, rb} = QuickBEAM.start(apis: false)
    busy2 = Task.async(fn -> QuickBEAM.eval(ra, "for (;;) {}", timeout: 2000) end)
    Process.sleep(100)
    t1 = QB.now()
    {:ok, 2} = QuickBEAM.eval(rb, "1 + 1")
    QB.report("separate_runtime_thread_eval_while_other_busy", latency_ms: Float.round((QB.now() - t1) / 1.0e6, 3))
    QB.report("beam_ping_probe_while_js_busy", QB.ping_probe(1000))
    Task.await(busy2, 10_000)

  :compat ->
    case QuickBEAM.JS.bundle_file("/work/compat.ts") do
      {:ok, _} -> IO.puts("quickbeam_bundle_file ok")
      {:error, errors} -> IO.puts("quickbeam_bundle_file errors=#{length(errors)} first=#{inspect(hd(errors).message)}")
    end
    # Engine check uses a bundle made by esbuild (browser conditions), so bundler gaps do not hide engine results.
    js = File.read!("/work/compat.bundle.js")
    for apis <- [[:browser], [:browser, :node]] do
      {:ok, rt} = QuickBEAM.start(apis: apis)
      case QuickBEAM.eval(rt, js) do
        {:ok, _} -> :ok
        other -> IO.puts("eval_error " <> inspect(other, limit: 20))
      end
      {:ok, names} = QuickBEAM.eval(rt, "globalThis.checkNames")
      results =
        for key <- names do
          case QuickBEAM.call(rt, "runOne", [key], timeout: 5_000) do
            {:ok, json} -> :json.decode(json)
            {:error, error} -> %{"name" => key, "ok" => false, "detail" => "call error: " <> inspect(error, limit: 8)}
          end
        end
      for c <- results, do: IO.puts("#{if c["ok"], do: "PASS", else: "FAIL"} apis=#{inspect(apis)} #{c["name"]} :: #{String.slice(c["detail"], 0, 300)}")
      IO.puts("quickbeam 0.11.3 apis=#{inspect(apis)}: #{Enum.count(results, & &1["ok"])}/#{length(results)} passed")
      QuickBEAM.stop(rt)
    end

  :vm ->
    source = """
    function mutate(n) {
      const counter = { hits: 0 };
      let total = 0;
      const add = (x) => { total += x; };
      for (let i = 0; i < n; i++) { counter.hits = counter.hits + 1; add(i & 7); }
      return counter.hits + total;
    }
    function fib(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }
    """
    {:ok, rt} = QuickBEAM.start(apis: false)
    {:ok, _} = QuickBEAM.eval(rt, source)
    {:ok, program} = QuickBEAM.VM.compile(source, filename: "bench.js")
    opts = [max_steps: 2_000_000_000, memory_limit: 4_000_000_000, timeout: 600_000]
    for {fun, arg} <- [{"mutate", 100_000}, {"fib", 20}, {"fib", 24}] do
      {:ok, expected} = QuickBEAM.call(rt, fun, [arg])
      native = for _ <- 1..5, do: (t0 = QB.now(); {:ok, ^expected} = QuickBEAM.call(rt, fun, [arg]); QB.now() - t0)
      vm = for _ <- 1..3 do
        t0 = QB.now()
        r = QuickBEAM.VM.call(program, fun, [arg], opts)
        {r, QB.now() - t0}
      end
      vm_ok = Enum.all?(vm, fn {r, _} -> r == {:ok, expected} end)
      vm_ms = vm |> Enum.map(fn {_, t} -> t end) |> Enum.sort() |> Enum.at(1)
      native_ms = native |> Enum.sort() |> Enum.at(2)
      QB.report("js_engine_compare", fun: fun, arg: arg, native_quickjs_ms_median: Float.round(native_ms / 1.0e6, 2),
        beam_interpreter_ms_median: Float.round(vm_ms / 1.0e6, 2), beam_interpreter_correct: vm_ok,
        ratio: Float.round(vm_ms / native_ms, 1), vm_first_result: inspect(elem(hd(vm), 0), limit: 5) |> String.slice(0, 160) |> String.replace(" ", "_"))
    end
end
```

`/tmp/bouy-beam-bench/quickbeam/diag.exs`

```elixir
Mix.install([{:quickbeam, "0.11.3"}])
{:ok, rt} = QuickBEAM.start(apis: [:browser])
probes = [
  {"setTimeout(0) resolves", "await new Promise((r) => setTimeout(r, 0)); return 1;"},
  {"queueMicrotask resolves", "return await new Promise((r) => queueMicrotask(() => r(7)));"},
  {"ReadableStream start() enqueue, read()", "const s = new ReadableStream({ start(c) { c.enqueue(1); c.close(); } }); return (await s.getReader().read()).value;"},
  {"ReadableStream pull() enqueue, read()", "const s = new ReadableStream({ pull(c) { c.enqueue(1); } }); return (await s.getReader().read()).value;"},
  {"ReadableStream async pull() enqueue, read()", "const s = new ReadableStream({ async pull(c) { c.enqueue(1); } }); return (await s.getReader().read()).value;"},
  {"for await over ReadableStream", "const s = new ReadableStream({ start(c) { c.enqueue(1); c.enqueue(2); c.close(); } }); let t = 0; for await (const x of s) t += x; return t;"},
  {"pipeThrough TransformStream", "const s = new ReadableStream({ start(c) { c.enqueue(1); c.enqueue(2); c.close(); } }).pipeThrough(new TransformStream({ transform(x, c) { c.enqueue(x * 10); } })); let t = 0; for await (const x of s) t += x; return t;"},
  {"tee()", "const [a, b] = new ReadableStream({ start(c) { c.enqueue(1); c.close(); } }).tee(); return (await a.getReader().read()).value + (await b.getReader().read()).value;"},
]
for {label, code} <- probes do
  t0 = System.monotonic_time(:millisecond)
  result = QuickBEAM.eval(rt, "await (async () => { #{code} })()", timeout: 3000)
  IO.puts("#{label} => #{inspect(result, limit: 4) |> String.slice(0, 110)} (#{System.monotonic_time(:millisecond) - t0} ms)")
end
```

`/tmp/bouy-beam-bench/quickbeam/vmcompat.exs`

```elixir
# Does QuickBEAM's BEAM-hosted interpreter (QuickBEAM.VM) run the zod / ai probe bundle?
Mix.install([{:quickbeam, "0.11.3"}])
js = File.read!("/work/compat.bundle.js")
t0 = System.monotonic_time(:millisecond)
compiled = QuickBEAM.VM.compile(js, filename: "compat.bundle.js")
IO.puts("vm_compile #{inspect(elem(compiled, 0))} ms=#{System.monotonic_time(:millisecond) - t0}")
case compiled do
  {:ok, program} ->
    for key <- ["zodParseTransform"] do
      t1 = System.monotonic_time(:millisecond)
      r = QuickBEAM.VM.call(program, "runOne", [key], max_steps: 2_000_000_000, memory_limit: 40_000_000_000, timeout: 240_000)
      IO.puts("vm_call #{key} ms=#{System.monotonic_time(:millisecond) - t1} result=#{inspect(r, limit: 12, printable_limit: 400)}")
    end
  {:error, e} -> IO.puts("vm_compile_error " <> inspect(e, limit: 20, printable_limit: 600))
end
IO.puts("beam_total_memory_mb=#{div(:erlang.memory(:total), 1_000_000)}")
```

### A.10 npm probe and feature scan

Setup and commands:

```sh
cd /tmp/bouy-beam-bench/compat && npm init -y && npm pkg set type=module
npm install --no-audit --no-fund zod@4.6.7 ai@7.0.142 esbuild@latest   # esbuild resolved to 0.28.2
npx esbuild compat.ts --bundle --format=iife --platform=browser --target=es2023 --outfile=compat.bundle.js
node run-node.mjs ./compat.ts && node run-node.mjs ./compat.bundle.js
node /tmp/bouy-beam-bench/feature-scan.mjs /Users/joshgalbreath/Code/bouy/node_modules/.pnpm
```

The feature scan reads the package builds from the repository's pnpm store, read-only. The probe uses the scratch install.

`/tmp/bouy-beam-bench/compat/compat.ts`

```typescript
// npm compatibility probe: zod 4.6.7 and ai 7.0.142 with a mock model (no network).
// The same file runs on Node and inside QuickBEAM (QuickJS-NG embedded in the BEAM).
import { z } from "zod";
import { generateText, streamText, tool, stepCountIs, Output } from "ai";
import { MockLanguageModelV4, simulateReadableStream } from "ai/test";

type Check = { name: string; ok: boolean; detail: string };

const usage = {
  inputTokens: { total: 3, noCache: 3, cacheRead: 0, cacheWrite: 0 },
  outputTokens: { total: 5, text: 5, reasoning: 0 },
};
const stop = { unified: "stop" as const, raw: "stop" };

const checks: Record<string, () => Promise<Check>> = {
  async zodParseTransform() {
    const User = z
      .object({
        name: z.string().min(1),
        age: z.number().int().nonnegative(),
        tags: z.array(z.string()).default([]),
        role: z.enum(["admin", "user"]),
      })
      .transform((u) => ({ ...u, label: `${u.name}:${u.role}` }));
    const good = User.parse({ name: "Ada", age: 36, role: "admin" });
    return {
      name: "zod parse + transform",
      ok: good.label === "Ada:admin" && good.tags.length === 0,
      detail: JSON.stringify(good),
    };
  },
  async zodSafeParse() {
    const User = z.object({
      name: z.string().min(1),
      age: z.number().int().nonnegative(),
      role: z.enum(["admin", "user"]),
    });
    const bad = User.safeParse({ name: "", age: -1, role: "x" });
    return {
      name: "zod safeParse issue count",
      ok: !bad.success && bad.error.issues.length === 3,
      detail: bad.success ? "0" : String(bad.error.issues.length),
    };
  },
  async zodJsonSchema() {
    const json = z.toJSONSchema(z.object({ city: z.string(), unit: z.enum(["c", "f"]) }));
    return {
      name: "zod toJSONSchema",
      ok: json.type === "object" && (json.required ?? []).length === 2,
      detail: JSON.stringify(json.required),
    };
  },
  async zodAsyncRefine() {
    const result = await z
      .string()
      .refine(async (s) => s.length > 2)
      .safeParseAsync("abcd");
    return { name: "zod async refine", ok: result.success, detail: String(result.success) };
  },
  async aiGenerateText() {
    const model = new MockLanguageModelV4({
      doGenerate: {
        content: [{ type: "text", text: "hello from mock" }],
        finishReason: stop,
        usage,
        warnings: [],
      },
    });
    const generated = await generateText({ model, prompt: "hi" });
    return {
      name: "ai generateText",
      ok: generated.text === "hello from mock",
      detail: generated.text,
    };
  },
  async aiStreamText() {
    const model = new MockLanguageModelV4({
      doStream: {
        stream: simulateReadableStream({
          chunks: [
            { type: "stream-start" as const, warnings: [] },
            { type: "text-start" as const, id: "t1" },
            { type: "text-delta" as const, id: "t1", delta: "str" },
            { type: "text-delta" as const, id: "t1", delta: "eamed" },
            { type: "text-end" as const, id: "t1" },
            { type: "finish" as const, finishReason: stop, usage },
          ],
        }),
      },
    });
    const streamed = streamText({ model, prompt: "hi" });
    let text = "";
    for await (const delta of streamed.textStream) text += delta;
    return { name: "ai streamText textStream", ok: text === "streamed", detail: text };
  },
  async aiToolLoop() {
    const model = new MockLanguageModelV4({
      doGenerate: [
        {
          content: [
            {
              type: "tool-call",
              toolCallId: "c1",
              toolName: "weather",
              input: JSON.stringify({ city: "Oslo" }),
            },
          ],
          finishReason: { unified: "tool-calls", raw: "tool_calls" },
          usage,
          warnings: [],
        },
        {
          content: [{ type: "text", text: "It is 7C in Oslo" }],
          finishReason: stop,
          usage,
          warnings: [],
        },
      ],
    });
    const weather = tool({
      description: "Current temperature for a city",
      inputSchema: z.object({ city: z.string() }),
      execute: async ({ city }) => ({ city, tempC: 7 }),
    });
    const run = await generateText({
      model,
      prompt: "weather?",
      tools: { weather },
      stopWhen: stepCountIs(3),
    });
    const outputs = run.steps.flatMap((step) => step.toolResults.map((result) => result.output));
    return {
      name: "ai tool loop with zod inputSchema",
      ok: run.text === "It is 7C in Oslo" && outputs.length === 1,
      detail: JSON.stringify(outputs),
    };
  },
  async aiOutputObject() {
    const model = new MockLanguageModelV4({
      doGenerate: {
        content: [{ type: "text", text: JSON.stringify({ city: "Oslo", unit: "c" }) }],
        finishReason: stop,
        usage,
        warnings: [],
      },
    });
    const structured = await generateText({
      model,
      prompt: "x",
      output: Output.object({ schema: z.object({ city: z.string(), unit: z.enum(["c", "f"]) }) }),
    });
    return {
      name: "ai Output.object with zod schema",
      ok: structured.output.city === "Oslo",
      detail: JSON.stringify(structured.output),
    };
  },
};

async function runOne(key: string): Promise<string> {
  const check = checks[key];
  if (check === undefined) return JSON.stringify({ name: key, ok: false, detail: "unknown check" });
  try {
    return JSON.stringify(await check());
  } catch (error) {
    return JSON.stringify({
      name: key,
      ok: false,
      detail: String((error as Error)?.stack ?? error),
    });
  }
}

const scope = globalThis as { runOne?: typeof runOne; checkNames?: string[] };
scope.runOne = runOne;
scope.checkNames = Object.keys(checks);
```

`/tmp/bouy-beam-bench/compat/run-node.mjs`

```javascript
await import(process.argv[2] ?? "./compat.ts");
let passed = 0;
for (const key of globalThis.checkNames) {
  const c = JSON.parse(await globalThis.runOne(key));
  if (c.ok) passed += 1;
  console.log(`${c.ok ? "PASS" : "FAIL"} ${c.name} :: ${c.detail.slice(0, 200)}`);
}
console.log(`node ${process.version}: ${passed}/${globalThis.checkNames.length} passed`);
```

`/tmp/bouy-beam-bench/feature-scan.mjs`

```javascript
// Counts occurrences of JS features and host APIs in installed npm package builds.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
const root = process.argv[2];
const targets = {
  "zod 4.6.7 (v4/core + v4/classic, .js)": [
    "zod@4.6.7/node_modules/zod/v4/core",
    "zod@4.6.7/node_modules/zod/v4/classic",
  ],
  "ai 7.0.142 (dist/index.js)": ["ai@7.0.142_zod@4.6.7/node_modules/ai/dist/index.js"],
  "@ai-sdk/provider-utils 5.0.61 (dist/index.js)": [
    "@ai-sdk+provider-utils@5.0.61_zod@4.6.7/node_modules/@ai-sdk/provider-utils/dist/index.js",
  ],
  "@ai-sdk/openai 4.0.95 (dist/index.js)": [
    "@ai-sdk+openai@4.0.95_zod@4.6.7/node_modules/@ai-sdk/openai/dist/index.js",
  ],
};
const patterns = {
  "new Proxy": /new Proxy\b/g,
  "Reflect.*": /\bReflect\.\w+/g,
  "WeakMap/WeakSet": /\bWeak(Map|Set)\b/g,
  "WeakRef/FinalizationRegistry": /\b(WeakRef|FinalizationRegistry)\b/g,
  "getter/setter syntax (get x()/set x())": /\b(get|set) [A-Za-z_$][\w$]*\s*\(/g,
  "Object.defineProperty": /Object\.defineProperty\b/g,
  "class private member (#x)": /this\.#[A-Za-z_]/g,
  "generator function*": /function\s*\*/g,
  "Symbol.asyncIterator": /Symbol\.asyncIterator/g,
  "async function": /async\s+(function\b|\(|[A-Za-z_$][\w$]*\s*=>|[A-Za-z_$][\w$]*\s*\()/g,
  await: /\bawait\b/g,
  "Promise.*": /\bPromise\.(all|race|any|allSettled|resolve|reject|withResolvers)\b/g,
  "new Function / eval": /new F(unction)?\(|\beval\(/g,
  "fetch(": /\bfetch\(/g,
  ReadableStream: /\bReadableStream\b/g,
  TransformStream: /\bTransformStream\b/g,
  "TextEncoder/TextDecoder(Stream)": /\bText(En|De)coder(Stream)?\b/g,
  "AbortController/AbortSignal": /\bAbort(Controller|Signal)\b/g,
  "setTimeout/clearTimeout": /\b(set|clear)Timeout\b/g,
  structuredClone: /\bstructuredClone\b/g,
  "crypto.*": /\bcrypto\.\w+/g,
  "Uint8Array/ArrayBuffer/DataView": /\b(Uint8Array|ArrayBuffer|DataView)\b/g,
  "process.env": /\bprocess\.env\b/g,
  "node: builtin import": /["']node:[a-z_/]+["']/g,
};
const files = (p) =>
  statSync(p).isDirectory()
    ? readdirSync(p).flatMap((f) => files(join(p, f)))
    : /\.m?js$/.test(p)
      ? [p]
      : [];
for (const [label, paths] of Object.entries(targets)) {
  const text = paths
    .flatMap((p) => files(join(root, p)))
    .map((f) => readFileSync(f, "utf8"))
    .join("\n");
  const counts = Object.entries(patterns)
    .map(([name, re]) => [name, (text.match(re) ?? []).length])
    .filter(([, n]) => n > 0);
  console.log(`== ${label}`);
  for (const [name, n] of counts) console.log(`  ${name.padEnd(42)} ${n}`);
}
```
