# Actor models: semantic lessons for Buoy

> Paths under `packages/`, `e2e/`, `examples/`, and `bench/` refer to commit [`90529d8`](https://github.com/JGalbss/buoy/tree/90529d8), the last commit with the Node runtime.

Track: actor-models. Date: 2026-10-16.

This note surveys actor systems and their programming models. It picks no engine. It states the semantics that any Buoy engine must implement, and it gives the evidence for each choice. The last section, "Recommended semantics for Buoy", is the contract that the engine tracks can test against.

## Evidence rules

- **Source** marks an external fact. A link follows it. Dates and versions appear where the source gives them.
- **Measured** marks a behavior observed on this machine: Apple M5 Pro, macOS (Darwin 25.6.0), Node v25.9.0, and Docker 29.4 (OrbStack Linux VM) for Erlang. Appendix A holds each script and its command. The scripts live outside the repository, in `/tmp/buoy-actor-research/`, so the appendix reproduces them in full.
- **Unverified** marks a claim I could not check. Each one names the check that would settle it.

This note contains no performance numbers. Defaults quoted from documentation, such as timeouts and capacities, are configuration facts. The local checks test semantics. They are not benchmarks.

## Key findings

1. Actor systems split on reentrancy. Orleans, Dapr, Restate, and Effect cluster entities serve one request at a time by default. Swift actors, Temporal workflows, Durable Objects, and Ray async actors interleave at `await`.
2. Turn-based systems deadlock on call cycles. Orleans and Dapr end the deadlock with a timeout. Restate needs an operator to cancel. Orleans and Dapr also offer call-chain reentrancy, which admits callbacks.
3. Failure semantics split in two. Orleans, Ray, and Durable Objects return the exception to the caller and keep actor state. Erlang, Akka, Proto.Actor, and Effect cluster restart the actor and discard its state.
4. Most systems keep the actor reference stable across a restart. Erlang creates a new pid and loses the old mailbox (measured on OTP 29).
5. FIFO per sender and receiver is the strongest order that most systems promise. Orleans gave up FIFO to scale. Pony gives causal order, and a 2018 study calls Pony's causal-delivery approach too expensive for distributed runtimes.
6. Erlang, Akka, and Proto.Actor default to unbounded mailboxes. Newer systems bound them. Effect cluster fails a send with `MailboxFull`, Durable Objects return an overloaded error, and Pony mutes senders.
7. Orleans 9+, Swift, Effect, Temporal, and Restate pass cancellation to the callee. An Akka or Erlang ask times out on the caller side only, and the callee keeps going.
8. Swift (`Sendable`, `sending`) and Pony (`iso`, `val`, `tag`) check sendability at compile time. TypeScript `readonly` cannot provide that check, because it is shallow and a mutable alias can still write.
9. When one isolate hosts many actors, npm module state is visible to all of them. Durable Objects document the same effect for objects in one isolate.

## Systems

Each subsection lists the semantic choices and their tradeoff.

### Erlang/OTP (the BEAM baseline)

- A supervisor restarts a failed child by calling its start function. The defaults are `intensity` 1 and `period` 5. More restarts than that within the period terminate all children and then the supervisor ([supervisor](https://www.erlang.org/doc/apps/stdlib/supervisor.html)). The limit exists "to prevent a situation where a process repeatedly dies for the same reason" ([supervision principles](https://www.erlang.org/doc/system/sup_princ.html)).
- Measured (A.2, OTP 29): the restarted child had a new pid. Three messages that sat in the old mailbox at the crash never reached the new child. A send to the old pid returned normally and delivered nothing.
- The only ordering guarantee is this: "if an entity sends multiple signals to the same destination entity, the order is preserved" ([Erlang reference manual](https://www.erlang.org/doc/system/ref_man_processes.html)).
- `gen_server:call/2` waits 5000 ms and then exits the caller. "Starting with OTP 24, gen_server:call uses process aliases, so late replies will not be received" ([gen_server](https://www.erlang.org/doc/apps/stdlib/gen_server.html)). The documentation gives no way for the server to learn about the timeout.
- Mailboxes have no capacity setting. The `max_heap_size` flag sets a heap limit per Erlang process, and the limit counts "any messages that are considered to be part of the heap" ([erlang:process_flag/2](https://www.erlang.org/doc/apps/erts/erlang.html)). Fred Hebert notes that since OTP 19 this flag can "force an early death if its memory usage is too high, including its mailbox" ([Handling Overload, 2016-11-24](https://ferd.ca/handling-overload.html)).
- Scheduling is preemptive by reduction count. The OTP source defines `CONTEXT_REDS 4000 /* Swap process out after this number */` ([erl_vm.h at 1137781](https://github.com/erlang/otp/blob/1137781950cd9c007d39471325cf71d877b8941d/erts/emulator/beam/erl_vm.h#L47)).
- Tradeoff: a restart gives a clean state and a new identity. Holders of the old pid must look up the name again, and queued messages disappear.

### Akka Typed

- An exception stops a typed actor unless a supervision strategy is defined: "the former are stopped if an exception is thrown and no supervision strategy is defined while in Classic they are restarted" ([fault tolerance](https://doc.akka.io/libraries/akka-core/current/typed/fault-tolerance.html)).
- A restart replaces the failed instance "with the fresh one inside the child's ActorRef". The new instance resumes the old mailbox, "with the notable exception that the message during which the failure occurred is not re-processed" ([supervision](https://doc.akka.io/libraries/akka-core/current/general/supervision.html)).
- While a backoff restart waits, "incoming messages and signals are stashed" up to a capacity. Past that capacity, "additional incoming messages are dropped" ([BackoffSupervisorStrategy](https://doc.akka.io/api/akka-core/current/akka/actor/typed/BackoffSupervisorStrategy.html)).
- A restart stops child actors by default, and `withStopChildren(false)` keeps them ([fault tolerance](https://doc.akka.io/libraries/akka-core/current/typed/fault-tolerance.html)).
- Invalid input "should rather be modelled as a part of the actor protocol than make the actor throw exceptions". Exceptions are for failures that are "unexpected or outside the control of the actor itself" ([fault tolerance](https://doc.akka.io/libraries/akka-core/current/typed/fault-tolerance.html)).
- Delivery is at-most-once. Order holds "for a given pair of actors" for direct `tell` only. The rule "is not transitive", and it covers user messages only ([message delivery reliability](https://doc.akka.io/libraries/akka-core/current/general/message-delivery-reliability.html)).
- The default mailbox is `SingleConsumerOnlyUnboundedMailbox`. Bounded mailboxes either send overflow to dead letters or block the sender for a configured push timeout ([mailboxes](https://doc.akka.io/libraries/akka-core/current/typed/mailboxes.html)).
- An `ask` requires a timeout. On timeout, "the receiving actor does not know and may still process it to completion" ([interaction patterns](https://doc.akka.io/libraries/akka-core/current/typed/interaction-patterns.html)).
- An Akka behavior never awaits a `Future`. `pipeToSelf` maps the result to a message, because a callback on another thread must not touch actor state ([interaction patterns](https://doc.akka.io/libraries/akka-core/current/typed/interaction-patterns.html)).
- Akka Streams use Reactive Streams demand signalling ([flows and basics](https://doc.akka.io/libraries/akka-core/current/stream/stream-flows-and-basics.html)). Buffers offer `dropHead`, `dropTail`, `dropBuffer`, `dropNew`, `backpressure`, and `fail` ([buffers and rates](https://doc.akka.io/libraries/akka-core/current/stream/stream-rate.html)).
- StreamRefs carry flow control across the network with cumulative demand messages. "A dropped element signal will cause the stream to fail." A `SinkRef` is "single-shot". The default subscription timeout is 30 seconds, and the module is marked "may change" ([stream refs](https://doc.akka.io/libraries/akka-core/current/stream/stream-refs.html)).
- Reliable delivery adds consumer-driven flow control and at-least-once delivery. It keeps order "as long as neither producer nor consumer crash", and it is also marked "may change" ([reliable delivery](https://doc.akka.io/libraries/akka-core/current/typed/reliable-delivery.html)).
- The dispatcher `throughput` setting caps the messages one actor takes before its thread moves to the next actor. A value of 1 is "as fair as possible" ([dispatchers](https://doc.akka.io/libraries/akka-core/current/typed/dispatchers.html)).
- Tradeoff: the stable `ActorRef` hides restarts from callers. Messages queued under the old state reach the new state. An ask timeout leaves an orphan request in the receiver.

### Microsoft Orleans

- Grains are virtual actors. They "always exist, virtually", and "their virtual existence is unaffected by the failure of a server" ([overview](https://learn.microsoft.com/en-us/dotnet/orleans/overview)). A grain reference "remains valid even after a complete system restart" ([grains](https://learn.microsoft.com/en-us/dotnet/orleans/grains/)).
- The default is turn-based. An activation serves each request "from beginning to completion before the next request can begin", including across awaits ([request scheduling](https://learn.microsoft.com/en-us/dotnet/orleans/grains/request-scheduling)).
- Interleaving is opt-in through five options: `[Reentrant]` per class, `[AlwaysInterleave]` and `[ReadOnly]` per method, `[MayInterleave]` per predicate, and `AllowCallChainReentrancy()` per call site ([request scheduling](https://learn.microsoft.com/en-us/dotnet/orleans/grains/request-scheduling)).
- Two grains that call each other can deadlock, and "Orleans determines that the call has timed out" ([request scheduling](https://learn.microsoft.com/en-us/dotnet/orleans/grains/request-scheduling)). The default response timeout is 30 seconds ([ResponseTimeout](https://learn.microsoft.com/en-us/dotnet/api/orleans.configuration.messagingoptions.responsetimeout)).
- The docs name the cost of the safe default: "This protection against concurrency bugs has a cost, primarily _liveness_" ([request scheduling](https://learn.microsoft.com/en-us/dotnet/orleans/grains/request-scheduling)).
- An exception propagates to the caller across hosts. "Exceptions thrown from grain methods don't cause the grain to be deactivated unless the exception inherits from" `InconsistentStateException` ([grains](https://learn.microsoft.com/en-us/dotnet/orleans/grains/)). The failure guide warns: "A grain's state might be partially updated" ([failure guide](https://learn.microsoft.com/en-us/dotnet/orleans/deployment/handling-failures)).
- Delivery is at-most-once by default, and at-least-once only with retries ([delivery guarantees](https://learn.microsoft.com/en-us/dotnet/orleans/implementation/messaging-delivery-guarantees)).
- Orleans gives no FIFO guarantee. The original implementation kept per-pair FIFO. The authors dropped it because per-pair state grows as n² sequence numbers and queues, and "FIFO message ordering is not required for most request-response applications". Callers express order by awaiting a reply before the next call ([Bernstein et al., MSR-TR-2014-41, §3.10](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/Orleans-MSR-TR-2014-41.pdf)). The current delivery-guarantees page states no ordering rule, so the 2014 report is the latest statement I found.
- Orleans deep-copies arguments and results, even between grains in one silo. `[Immutable]` and `Immutable<T>` skip the copy, as "a mutual, dual-sided commitment" ([immutability](https://learn.microsoft.com/en-us/dotnet/orleans/host/configuration-guide/serialization-immutability)).
- Since Orleans 9, grain methods accept a `CancellationToken`. A request cancelled in the queue "is cancelled without being executed". While the call is active, the runtime forwards cancellation to the callee. `CancelRequestOnTimeout` defaults to true. Cancellation is cooperative ([cancellation tokens](https://learn.microsoft.com/en-us/dotnet/orleans/grains/cancellation-tokens)).
- A grain method may return `IAsyncEnumerable<T>`. Elements travel in batches (default 100), the stream is "scoped to single call", and backpressure is "built-in". Orleans Streams, the pub/sub feature, leave backpressure to the provider ([grains](https://learn.microsoft.com/en-us/dotnet/orleans/grains/)).
- Scheduling is cooperative on a few threads. The technical report names the weakness: "a poorly behaved component can take up an entire processor" ([MSR-TR-2014-41, §3.6](https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/Orleans-MSR-TR-2014-41.pdf)).
- Tradeoff: turn-based safety costs liveness. Keeping state after an exception favors availability and risks partial updates.

### Swift concurrency

- "Actor-isolated functions are reentrant." Other calls may enter the actor while a method waits at `await` ([SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)).
- SE-0306 gives three reasons: reentrancy "eliminates a source of deadlocks", avoids "unnecessarily blocking work on actors", and allows better scheduling of higher-priority tasks.
- SE-0306 also names the cost: reentrant actors "are not automatically protecting from the 'high level' kinds of races".
- Non-reentrant actors "can result in deadlock if a task involves calling back into the actor". Task-chain reentrancy was deferred, because it "doesn't seem to have been tried at scale" and no efficient implementation technique was known ([SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)).
- Cross-actor calls need `await`, and "the argument and result types must conform to `Sendable`" ([SE-0306](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)).
- Aggregates of `Sendable` values are `Sendable`, and actors conform implicitly. A class conforms only as "a final class containing only immutable stored properties of types that conform to Sendable". `@Sendable` closures "can only use by-value captures" of `Sendable` values. `@unchecked` opts out ([SE-0302](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md)).
- Every global variable must "either be isolated to a global actor" or be immutable and `Sendable`. `nonisolated(unsafe)` opts out ([SE-0412](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0412-strict-concurrency-for-global-variables.md)).
- A `sending` parameter accepts a non-`Sendable` value "as long as the value is in a disconnected region". Afterward, "the caller cannot use the argument value again". This builds on region-based isolation from SE-0414 ([SE-0430](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md)).
- The Swift 6 language mode reports potential data races "as compiler errors". Swift 5.10 reported them as warnings ([Announcing Swift 6, 2024-09-17](https://www.swift.org/blog/announcing-swift-6/)).
- Cancellation is cooperative. A flag is set and "never cleared", and registered cancellation callbacks fire at once. Cancelling a task group cancels its child tasks ([SE-0304](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md)).
- A called async function "is still running as part of the same task" ([SE-0304](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md)). Task-local values are readable "from any function running within a task context" ([SE-0311](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0311-task-locals.md)). An actor method called with `await` therefore sees the caller's cancellation and task-locals. This is an inference from the two proposals.
- Distributed actors are written "as-if it was remote". Their methods gain an implicit `throws`, and parameters and results must meet a serialization requirement such as `Codable` ([SE-0336](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md)).
- Tradeoff: reentrancy buys liveness and gives up invariants across `await`. Sendable checking needed region analysis (SE-0414, SE-0430) before any non-`Sendable` value could cross a boundary.

### Pony

- Only three reference capabilities can go to another actor: `iso` ("read and write unique"), `val` ("globally immutable"), and `tag` (identity only). `trn`, `ref`, and `box` "don't make the guarantees we need in order to be safe" ([passing and sharing](https://tutorial.ponylang.io/reference-capabilities/passing-and-sharing.html)).
- "Each actor will only execute one behaviour at a time" ([actors](https://tutorial.ponylang.io/types/actors.html)).
- Behaviours and actor constructors "cannot be partial", so no error escapes a behaviour. Errors carry no type or value ([errors](https://tutorial.ponylang.io/expressions/errors.html)).
- Messages from A to B "will be processed by Actor B in the same order", and a causally later message from C "will always arrive after" its cause ([runtime FAQ](https://ponylang.io/faq/runtime)).
- "Any actor that sends a message to an overloaded actor gets muted" until the receiver's queue shrinks. There is no API for it ([backpressure](https://tutorial.ponylang.io/runtime-basics/backpressure)).
- The runtime starts one scheduler thread per physical core. An idle thread steals from another thread's queue. A behaviour "will not be interrupted partway through", an actor takes a batch of messages per turn, and a long behaviour "monopolizes a scheduler thread" ([scheduler](https://tutorial.ponylang.io/runtime-basics/scheduler)).
- Plyukhin and Agha (AGERE 2018) state that Pony's causal-delivery approach to actor garbage collection "is too expensive for a distributed actor runtime" ([Concurrent Garbage Collection in the Actor Model](https://osl.cs.illinois.edu/publications/conf/AGERE/Plyukhin2018.html)).
- Tradeoff: the type system proves data-race freedom before the program starts. Causal order is cheap on one machine and expensive across machines.

### Ray actors

- A synchronous actor takes tasks from one submitter "in the order they were submitted". Tasks from different submitters have no order, and "asynchronous or threaded actors do not guarantee the task execution order" ([task orders](https://docs.ray.io/en/latest/ray-core/actors/task-orders.html)).
- An async actor multiplexes tasks on one event loop. "By default, 1000 tasks can be running concurrently" ([async actors](https://docs.ray.io/en/latest/ray-core/actors/async_api.html)).
- An application exception becomes the task's result: "Ray wraps the original exception in a `RayTaskError`". Ray retries it only if `retry_exceptions` is set ([task fault tolerance](https://docs.ray.io/en/latest/ray-core/fault_tolerance/tasks.html)).
- `max_restarts` defaults to 0. A restart recreates state "by rerunning its constructor". Actor tasks are at-most-once by default ([actor fault tolerance](https://docs.ray.io/en/latest/ray-core/fault_tolerance/actors.html)).
- The retry rules count user exceptions apart from actor crashes ([actor fault tolerance](https://docs.ray.io/en/latest/ray-core/fault_tolerance/actors.html)). This implies that an exception leaves the actor alive with its state. Unverified: no page states it directly. A two-call test against a Ray actor would settle it.
- `ray.cancel` is best-effort. It unschedules a queued task. A sync task in progress sees a flag. An async task in progress gets `asyncio` cancellation at its next `await`. `recursive=True` extends cancellation to child tasks ([actors](https://docs.ray.io/en/latest/ray-core/actors.html)).
- "Ray eagerly executes a generator task to completion regardless of whether the caller is polling" ([generators](https://docs.ray.io/en/latest/ray-core/ray-generator.html)).
- Tradeoff: exceptions keep the actor alive and expose partial updates. Eager generators give up backpressure.

### Dapr actors

- Dapr activates an actor on its first request and garbage-collects the in-memory object after an idle period ([actor features](https://docs.dapr.io/developing-applications/building-blocks/actors/actors-features-concepts/)).
- Dapr enforces turn-based concurrency with "a per-actor lock". The guarantee covers methods, timers, and reminder callbacks ([actor features](https://docs.dapr.io/developing-applications/building-blocks/actors/actors-features-concepts/)).
- "Actors can deadlock on each other if there is a circular request between two actors." The runtime times out actor calls and throws to the caller ([actor features](https://docs.dapr.io/developing-applications/building-blocks/actors/actors-features-concepts/)).
- Opt-in reentrancy matches requests to their call chain through the `Dapr-Reentrancy-Id` header. `maxStackDepth` defaults to 32 ([reentrancy](https://docs.dapr.io/developing-applications/building-blocks/actors/actor-reentrancy/)).
- Timers stop on deactivation. Reminders persist "across actor deactivations and failovers" and retry three times at 1-second intervals by default. Both respect turn-based concurrency ([timers and reminders](https://docs.dapr.io/developing-applications/building-blocks/actors/actors-timers-reminders/)).
- Tradeoff: call-chain reentrancy needs a chain identifier on every request. Dapr carries it in a request header.

### Cloudflare Durable Objects

- "Durable Objects are single-threaded and cooperatively multi-tasked", and each one has a globally unique name ([what are Durable Objects](https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/)).
- Input gates block new events while synchronous JavaScript is in progress and during storage operations. "Non-storage I/O like `fetch()` or writing to R2 allows other requests to interleave" ([rules](https://developers.cloudflare.com/durable-objects/best-practices/rules-of-durable-objects/)).
- Output gates hold "any new outgoing network messages" until pending writes complete. If a write fails, the held messages "will be discarded and replaced with errors", and the object restarts "from scratch". Writes made without an intervening `await` "are automatically grouped together and stored atomically" ([Kenton Varda, 2021-08-03](https://blog.cloudflare.com/durable-objects-easy-fast-correct-choose-three/)).
- Uncaught exceptions "will be propagated to the callsite of the client", with `.remote` set for user-code errors. Many exceptions leave the stub "broken", and the guidance is to create a new stub ([error guide](https://developers.cloudflare.com/durable-objects/best-practices/error-handling/)).
- `blockConcurrencyWhile()` blocks all other events. If its callback throws or exceeds its 30-second timeout, the object is reset ([state API](https://developers.cloudflare.com/durable-objects/api/state/)). Using it across I/O is "an anti-pattern" ([rules](https://developers.cloudflare.com/durable-objects/best-practices/rules-of-durable-objects/)).
- An object with too many requests queues them, then returns "an overloaded error to the caller" ([limits](https://developers.cloudflare.com/durable-objects/platform/limits/)). Errors with `.overloaded` "should not be retried" ([error guide](https://developers.cloudflare.com/durable-objects/best-practices/error-handling/)).
- "Memory is measured per isolate (which can host multiple Durable Objects)", and one instance "may share global memory with other instances defined in the same Worker code" ([in-memory state](https://developers.cloudflare.com/durable-objects/reference/in-memory-state/)).
- Workers RPC passes structured-cloneable values. It replaces functions and `RpcTarget` instances with stubs, and it streams `ReadableStream` and `WritableStream` "with automatic streaming flow control". Ownership of a stream moves to the recipient. The RPC page states no ordering guarantee ([RPC](https://developers.cloudflare.com/workers/runtime-apis/rpc/)). Stubs can be released with `using` ([RPC lifecycle](https://developers.cloudflare.com/workers/runtime-apis/rpc/lifecycle/)).
- The Agents SDK requires Durable Objects, and "an instance of an Agent is globally unique" ([Agents API](https://developers.cloudflare.com/agents/api-reference/agents-api/)).
- Tradeoff: interleaving at non-storage I/O keeps objects responsive and opens races across `fetch()`. Many objects per isolate saves memory, and it makes module state and memory limits per isolate.

### Proto.Actor

- The supervision directives are Resume, Restart, Stop, and Escalate. A restart creates a new instance "inside the child's `PID`". The new actor "resumes processing its mailbox", and "the message during which the failure occurred is not re-processed". `OneForOneStrategy` is the default ([supervision.md](https://github.com/asynkron/protoactor-website/blob/a28c8e4c16a388408efbf09df395023fb82d4338/hugo/content/docs/supervision.md)).
- System messages use their own queue and go before user messages. Supervision events "are not deterministically ordered relative to ordinary messages" ([supervision.md](https://github.com/asynkron/protoactor-website/blob/a28c8e4c16a388408efbf09df395023fb82d4338/hugo/content/docs/supervision.md), [mailboxes.md](https://github.com/asynkron/protoactor-website/blob/d4735adebb8681c964cb99d17dc7c6ad9ab03ddc/hugo/content/docs/mailboxes.md)).
- The default mailbox is unbounded. A bounded mailbox sends new messages to dead letters when full, with dropping-head and dropping-tail variants. The dispatcher limits the messages per mailbox pass so other mailboxes get a thread ([mailboxes.md](https://github.com/asynkron/protoactor-website/blob/d4735adebb8681c964cb99d17dc7c6ad9ab03ddc/hugo/content/docs/mailboxes.md)).
- An `await` inside `Receive` blocks the actor. `Context.ReenterAfter(task, callback)` sends the continuation back to the actor as a message, so other messages get served meanwhile ([reenter.md](https://github.com/asynkron/protoactor-website/blob/9a4122bbc4fd89e97f2adff9c1efdf4576c7416c/hugo/content/docs/reenter.md)).
- Tradeoff: explicit reentrancy makes every interleaving point visible in the code. It also forces the method into callback style.

### Effect 4: fibers, queues, and cluster entities

Effect 4.0 shipped on 2026-09-30 ([release post](https://effect.website/blog/releases/effect/40)). npm lists `effect` 4.0.5 as `latest` on 2026-10-16. The repository's `AGENTS.md` makes Effect 4 the house style for Buoy's TypeScript source.

- Child fibers "will be terminated either when they end naturally, or when their parent fiber is terminated". `forkDaemon` detaches, and `forkScoped` and `forkIn` bind to a scope. `Fiber.interrupt` "waits until the fiber has fully terminated" ([fibers](https://effect.website/docs/concurrency/fibers/)). In a race, the losing effect "will be interrupted" ([basic concurrency](https://effect.website/docs/concurrency/basic-concurrency/)).
- Expected errors are typed failures. Defects from `Effect.die` represent "unrecoverable defects", and "There is no sensible way to recover from defects" ([unexpected errors](https://effect.website/docs/error-management/unexpected-errors/)).
- A bounded queue "applies back-pressure when full". A dropping queue "discards new values". A sliding queue "removes old values" ([queue docs](https://effect.website/docs/concurrency/queue/)). In 4.0, `Queue.make` takes `strategy: "suspend" | "dropping" | "sliding"`, and it defaults to an unbounded `"suspend"` queue ([Queue.ts at d8918cb](https://github.com/Effect-TS/effect/blob/d8918cbd0eb3b83c266f8d5ccd8b20b655632600/packages/effect/src/Queue.ts)).
- A cluster entity serves requests with concurrency 1 unless configured otherwise ([entityManager.ts at 5d301cc](https://github.com/Effect-TS/effect/blob/5d301cc7aaf23e40cc8b59feea9389f747048d02/packages/effect/src/cluster/internal/entityManager.ts)). The default mailbox capacity is 4096, and the default idle time is 1 minute ([ShardingConfig.ts at 5a67e0b](https://github.com/Effect-TS/effect/blob/5a67e0b3a8118dd7be709a56d6d7af4f10e9c4f3/packages/effect/src/cluster/ShardingConfig.ts)). When the mailbox is full, "new messages fail with a `MailboxFull` error" ([cluster delivery post](https://effect.website/blog/module-of-the-week/cluster-delivery)).
- A defect in an entity logs "Defect in entity, restarting". The runtime rebuilds the entity after the defect retry schedule. It then replays every delivered request that has not completed ([entityManager.ts](https://github.com/Effect-TS/effect/blob/5d301cc7aaf23e40cc8b59feea9389f747048d02/packages/effect/src/cluster/internal/entityManager.ts)).
- Cluster offers at-most-once delivery and at-least-once delivery for persisted messages. "Exactly-once delivery isn't possible." A runner that takes over a shard "reads every unprocessed message for that shard" and delivers it again ([cluster delivery post](https://effect.website/blog/module-of-the-week/cluster-delivery)).
- Tradeoff: the split between typed failures and defects matches the split between a reply and a crash. Replay after a defect suits persisted messages, and it also redelivers the request that caused the defect.

### XState

`xstate` 5.33.2 is `latest` on npm and 6.0.0-alpha.66 is `alpha` (npm registry, 2026-10-16).

- "Actors process one message at a time" from an internal mailbox ([actor model](https://stately.ai/docs/actor-model)).
- An invoked actor starts when its state is entered and stops when the state is exited. A transition that re-enters the state starts a new one ([invoke](https://stately.ai/docs/invoke)).
- A failing invoked actor sends `xstate.error.actor.<id>` to the parent's `onError` transition. "If the `onError` transition is missing, and the Promise is rejected, the error will throw" ([invoke](https://stately.ai/docs/invoke)).
- `reportUnhandledError` rethrows an unhandled error inside `setTimeout`, for global reporters ([reportUnhandledError.ts at 94037fe](https://github.com/statelyai/xstate/blob/94037fe9c429839f0508ddcd287718b659276e3b/packages/core/src/reportUnhandledError.ts)).
- XState has no restart supervision. In the v6 alpha docs, an unrecovered error sets the status to `'error'`, and the actor "stops all of its children" ([v6 lifecycle](https://stately.ai/docs/xstate/v6/lifecycle-and-errors)).
- Tradeoff: statecharts make actor state explicit and inspectable. Recovery is the parent's job.

### JavaScript actor libraries: nact and comedy

- nact is "Inspired by the approaches taken by Akka and Erlang" ([nact](https://github.com/nactio/nact)). Its supervision decisions are stop, stopAll, reset, resetAll, resume, and escalate. "If a stateful actor crashes, it is stopped by default" ([nact supervision](https://nact.xyz/en_uk/lesson/javascript/supervision)). Its latest npm release is 7.6.2 (2022-05-10), and the GitHub API reports the last push on 2023-03-05.
- comedy places an actor `in-memory` (default), `forked` (child process), `threaded` (worker thread), or `remote`. With `onCrash: "respawn"`, a crashed forked actor is replaced by a new one with a new ID and empty state. Respawn covers forked and remote actors only, because an in-memory failure means "the whole process has failed" ([comedy](https://github.com/untu/comedy)). Its latest npm release is 2.1.7 (2022-06-13), and the GitHub API reports the last push on 2025-09-06.
- Tradeoff: both libraries show that Akka-style supervision fits in JavaScript. comedy shows that fault containment in Node needs a thread or process boundary. Neither has published a release since 2022.

### Durable workflow systems: Temporal, Restate, Inngest

Temporal:

- In a workflow, async Signal and Update methods and the main workflow method interleave, "with switching occurring between them at `await` calls". The docs recommend `workflow.condition` and a mutex ([message passing](https://docs.temporal.io/develop/typescript/message-passing)).
- Cancellation scopes form a tree, and "cancellation propagates from outer scopes to inner ones" and to activities, timers, and triggers. `nonCancellable` shields cleanup, and `withTimeout` cancels the scope on expiry ([cancellation scopes](https://docs.temporal.io/develop/typescript/workflows/cancellation-scopes)).
- The parent close policy defaults to Terminate. Abandon and Request Cancel are the alternatives ([parent close policy](https://docs.temporal.io/parent-close-policy)).
- "Workflow code must be deterministic to support replay." External interactions, including "LLM/AI invocations", belong in activities ([workflow definition](https://docs.temporal.io/workflow-definition)).
- Event history is "limited to 51,200 Events or 50 MB" ([limits](https://docs.temporal.io/workflow-execution/limits)).
- The TypeScript SDK reuses one V8 context per worker thread by default. `workflowThreadPoolSize` is "Ignored if `debugMode` is enabled" ([WorkerOptions](https://typescript.temporal.io/api/interfaces/worker.WorkerOptions)).

Restate:

- A Virtual Object is keyed. "At most one handler with write access can run at a time per object key." Methods marked `shared` are read-only and concurrent ([services](https://docs.restate.dev/concepts/services)).
- "Calls to a Virtual Object execute in order of arrival, serially", and other invocations "may interleave" between two calls from one sender ([service communication](https://docs.restate.dev/develop/ts/service-communication)).
- Request-response calls between exclusive methods "may lead to deadlocks", both A→B→A and A→B→C→A. The remedy is to cancel from the UI or CLI ([service communication](https://docs.restate.dev/develop/ts/service-communication)).
- "Cancellation propagates recursively through the call graph" and arrives at the next await point. One-way and delayed sends "are detached from the call tree" ([invocations guide](https://docs.restate.dev/services/invocation/managing-invocations)).

Inngest:

- Inngest resumes a function "by replaying your handler and returning saved step results". "Code outside a step can run again each time the handler replays" ([Inngest steps](https://www.inngest.com/docs/learn/how-functions-are-executed)).
- A concurrency limit with a `key` holds separately for each key value, and excess steps wait in a queue ([concurrency](https://www.inngest.com/docs/guides/concurrency)).
- `cancelOn` events and the API stop a function before its next step. "If a step is already executing, that step finishes" ([cancellation](https://www.inngest.com/docs/features/inngest-functions/cancellation)).

Tradeoff across the three: replay makes long workflows durable and constrains the code between steps. Per-key serialization (Restate, Inngest) gives actor-like state semantics with a durable journal.

## Local checks

| Check                       | Command                                                  | Result                                                                                                                                                                                                                                                                                                                                                                                            |
| --------------------------- | -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A.1 Turn semantics in Node  | `node /tmp/buoy-actor-research/node/semantics.mjs`       | A plain object with async methods lost an update (two increments gave 1). A turn-based mailbox gave 2. A user→room→user callback deadlocked until the 300 ms deadline cancelled the queued callback. Call-chain reentrancy through `AsyncLocalStorage` completed the same cycle. Aborting the caller aborted the request in progress through its `AbortSignal` and removed the queued one.        |
| A.2 Erlang restart identity | see Appendix A.2                                         | OTP 29: new pid after restart; 3 queued messages lost; a send to the old pid returned normally.                                                                                                                                                                                                                                                                                                   |
| A.3 Isolation in Node       | `node /tmp/buoy-actor-research/node/isolation.mjs`       | A worker with `maxOldGenerationSizeMb: 32` hit `ERR_WORKER_OUT_OF_MEMORY` and exited alone. `worker.terminate()` stopped a worker stuck in `for (;;) {}`. In the main isolate, a timer error created inside `run("planner", …)` reached `uncaughtException` with the store `planner`. A floating promise rejected inside `run("critic", …)` reached `unhandledRejection` with the store `critic`. |
| A.4 `ai` abort              | `node /tmp/buoy-actor-research/node/ai-abort.mjs`        | `ai@7.0.142` `streamText` passed the caller's signal to the model's `doStream`, and the signal was aborted. The `textStream` loop then ended without an exception. `textStream` is a `ReadableStream`.                                                                                                                                                                                            |
| A.5 `ai` backpressure       | `node /tmp/buoy-actor-research/node/ai-backpressure.mjs` | With 200 chunks available and a slow reader, the mock model stream had been pulled 18 times after the first read, then once more per read. The SDK propagates demand with a bounded read-ahead.                                                                                                                                                                                                   |
| A.6 Freeze and clone limits | `node /tmp/buoy-actor-research/node/checks.mjs`          | `Object.freeze` is shallow. A frozen `Date` still changed through `setTime`, and a frozen `Map` still accepted `set`. Freezing a non-empty `Uint8Array` threw `TypeError`. `structuredClone` threw `DataCloneError` for a function and a symbol, and it turned a class instance into a plain object without its private field. An async generator advanced only on `next()`.                      |

The repository's lint preset sets `"typescript/no-floating-promises": "error"` (`tools/oxlint/guardrails/preset.ts`, line 112). Q5 depends on that rule.

## Buoy design questions

### Q1. Reentrant at await, turn-based, or call-chain reentrant

| Model                 | Systems                                                                                                                                                          | Failure mode                                                                 |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Turn-based            | Orleans (default), Dapr, Restate exclusive methods, Effect cluster (concurrency 1). Erlang, Akka, Proto.Actor, Pony, and XState also take one message at a time. | Call cycles deadlock until a timeout or an operator ends them.               |
| Reentrant at `await`  | Swift actors, Temporal workflows, Durable Objects (non-storage I/O), Ray async actors                                                                            | State invariants break across `await`. Swift calls these "high level" races. |
| Call-chain reentrant  | Orleans `AllowCallChainReentrancy()` (per call site), Dapr reentrancy (per actor type)                                                                           | A callback sees the suspended turn's intermediate state.                     |
| Explicit continuation | Akka `pipeToSelf`, Proto.Actor `ReenterAfter`                                                                                                                    | The author splits each method at every await.                                |

**Recommendation.**

1. Turn-based by default. A call holds the actor until the method's promise settles, across every `await`.
2. Call-chain reentrancy on by default. A request that carries the call chain of the actor's suspended turn enters at once. Requests from other chains wait.
3. A method marked `interleave` may start while a turn waits. Use it for read-only queries and control messages such as status and cancel. The checker gives such methods a read-only view of actor state.
4. The runtime tracks wait-for edges inside one isolate. A new edge that closes a cycle fails that call with a typed `Deadlock` error that names the cycle. Across isolates and nodes, deadlines end deadlocks, as in Orleans and Dapr.

**Evidence.**

- Agent turns contain long LLM awaits. With interleaving at `await`, two user messages can edit one conversation history at once. A.1 shows the lost update in a plain async object.
- Agent graphs call back, for example when a sub-agent asks its parent for context. Without reentrancy, each callback deadlocks until its deadline (A.1, case 3), which is the Orleans, Dapr, and Restate failure mode.
- Call-chain reentrancy admits only calls that the waiting turn caused. Orleans and Dapr ship it. Swift deferred it for implementation reasons: no trial at scale and no known efficient technique in its runtime. In Node, `AsyncLocalStorage` carries the chain ID across awaits. A.1, case 4, resolves the cycle with a 38-line actor class.
- Status and cancel must not wait behind a multi-minute LLM turn. Orleans meets the same need with `[AlwaysInterleave]` and `[ReadOnly]`.

**Unverified.** The cost of chain tracking and cycle detection per call; measure it in `bench/`. Whether the checker can enforce a read-only `this` in `interleave` methods without false positives; prototype it in `packages/checker`.

### Q2. Crash and reset, or reject the caller only

| Behavior                         | Systems                                                                                                  |
| -------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Reject the caller and keep state | Orleans, Ray (inferred, see Ray), Durable Objects (outside the reset cases)                              |
| Crash and reset state            | Erlang/OTP, Akka (stop in Typed, restart in Classic), Proto.Actor, nact (stop), Effect cluster (defects) |
| No exception crosses a behaviour | Pony                                                                                                     |

**Recommendation.**

1. Use two failure channels. A declared failure is part of the method's return type, for example a tagged error union. It rejects the caller and leaves the actor and its state in place.
2. Any exception that escapes a method is a defect. The caller receives `ActorDefect`. Other in-flight calls on the actor, such as `interleave` calls or chain callbacks, receive `ActorRestarting`. The runtime discards the in-memory state and tells the supervisor.
3. The default supervisor policy is restart with exponential backoff under a restart-intensity limit. Past the limit, the supervisor stops the actor and escalates. OTP's default (1 restart in 5 seconds) is a starting point to tune.
4. An error from a timer or a floating promise created inside a turn is a defect of the actor that created it. `AsyncLocalStorage` attributes the error in `uncaughtException` and `unhandledRejection` listeners (A.3).
5. A restarted actor starts from its constructor state. Once durability exists, it starts from its last durable snapshot instead.

**Evidence.**

- JavaScript object state has no transactions, so an exception in the middle of a method leaves partial writes. Orleans warns about partially updated state. Proto.Actor's supervision guide states that corrupt internal state cannot be ruled out after a failure.
- Akka models validation errors in the protocol and reserves exceptions for unexpected failures. Effect splits typed failures from defects and states that defects have no sensible recovery. Effect cluster restarts an entity on a defect and returns typed failures to the caller.
- TypeScript has no checked exceptions, so a thrown type cannot be declared. A returned error union can be checked.
- The cost is lost in-memory state after a defect. Durable snapshots lower that cost. Until they exist, a reset agent loses its context.

### Q3. ActorRef survival across a restart, and the fate of queued messages

| System          | Reference after restart               | Queued messages                                               | Message that caused the failure |
| --------------- | ------------------------------------- | ------------------------------------------------------------- | ------------------------------- |
| Erlang/OTP      | New pid (measured)                    | Lost (measured: 3 of 3)                                       | Lost                            |
| Akka            | Same `ActorRef`                       | Kept. During backoff, stashed up to a capacity, then dropped. | Not reprocessed                 |
| Proto.Actor     | Same `PID`                            | Kept                                                          | Not reprocessed                 |
| Orleans         | Virtual reference, always valid       | No reset on exception                                         | Exception goes to the caller    |
| Ray             | Calls succeed again after recovery    | In-flight tasks fail unless `max_task_retries` is set         | Exception goes to the caller    |
| Durable Objects | Stub can be "broken"; make a new stub | Not documented                                                | Exception goes to the caller    |
| Effect cluster  | Entity address is stable              | Kept                                                          | Replayed after the rebuild      |

**Recommendation.**

1. An `ActorRef` is a stable logical address. It survives restarts and dies only when the actor stops.
2. Queued messages stay queued and go to the next incarnation.
3. The message that caused a defect is not redelivered. Its caller receives `ActorDefect`.
4. During restart backoff, the mailbox keeps accepting messages up to its capacity, under its overflow policy.
5. After a stop, queued asks fail with `ActorStopped`, and later sends go to a dead-letter channel.
6. Watchers receive `Restarted { incarnation, cause }` and `Stopped { cause }`. The incarnation number lets a holder detect lost state.
7. Durable actors can later opt into redelivery of the in-flight request, with a retry policy and an attempt limit.

**Evidence.** Agents pass references to other agents, tools, and user interfaces. A new identity per restart, as in Erlang, forces every holder to look the actor up again. Akka, Proto.Actor, Orleans, Ray, and Effect cluster keep the reference stable. Dropping the failing message stops a poison message from crashing every incarnation (Akka, Proto.Actor). Redelivery fits persisted, idempotent requests, which is the Effect cluster model.

**Risk.** Messages written for the old state reach the new state. Proto.Actor warns about this case for `AllForOneStrategy`.

### Q4. Message ordering

| Guarantee                           | Systems                                                                                                                |
| ----------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| FIFO per sender and receiver        | Erlang, Akka (direct `tell`), Proto.Actor mailbox, Ray sync actors (per submitter), Restate (arrival order per object) |
| Causal                              | Pony                                                                                                                   |
| None                                | Orleans, Ray async and threaded actors                                                                                 |
| Control messages outside user order | Akka, Proto.Actor                                                                                                      |

**Recommendation.**

1. FIFO per sender and receiver for every user message, `tell` and `ask` alike, in every placement. The sender is an actor or an external client.
2. No causal or total order. Code that needs a dependency awaits the reply before the next send, as Orleans recommends.
3. Control messages (cancel, stop, supervision signals) travel in a separate priority queue and may overtake user messages.
4. Retries void the guarantee unless messages carry sequence numbers. The durable mode must add them, as in Akka reliable delivery. Ray documents the same break under retries.
5. `interleave` methods start in arrival order and can finish in any order.

**Evidence.** Per-pair FIFO is cheap whenever one ordered channel connects two actors. Causal order is cheap on one machine (Pony) and too expensive for distribution (Plyukhin and Agha). Orleans dropped even FIFO because of per-pair state across a cluster. Buoy only promises FIFO where a channel already exists.

**Unverified.** That messages on one Node `MessagePort` between two workers arrive in send order. A test that sends numbered messages between two workers would settle it.

### Q5. Mailbox overflow policies and the default

| Policy                  | Systems                                                                                                                |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Unbounded               | Erlang (with optional `max_heap_size` kill), Akka default, Proto.Actor default, Effect `Queue.unbounded`               |
| Backpressure the sender | Effect `Queue.bounded` (`"suspend"`), Akka Streams `backpressure`, Pony muting, Akka bounded mailbox with push timeout |
| Fail fast               | Effect cluster `MailboxFull`, Durable Objects overloaded error, Akka Streams `fail`                                    |
| Drop the newest         | Effect `Queue.dropping`, Akka `dropNew` and `NonBlockingBoundedMailbox`, Proto.Actor dropping tail                     |
| Drop the oldest         | Effect `Queue.sliding`, Akka `dropHead`, Proto.Actor dropping head                                                     |

**Recommendation.**

1. Every mailbox is bounded. An unbounded mailbox is an explicit opt-in.
2. The policies are `backpressure`, `fail`, `dropNewest`, and `dropOldest`.
3. The default inside the runtime is `backpressure`. `send` and `ask` return a promise that settles when the message is in the mailbox or the deadline expires.
4. `trySend` never waits. It returns `Enqueued` or `Full`.
5. Requests from outside the runtime, such as HTTP calls and webhooks, use `fail`. The client receives `Overloaded` and must not retry at once, as the Durable Objects guidance states.
6. Control messages bypass the bound.
7. A benchmark in `bench/` sets the default capacity. Effect cluster's 4096 is one reference point.

**Evidence.** Unbounded queues hide overload until memory is exhausted: "You're making failures more rare, but you're making their magnitude worse" ([Queues Don't Fix Overload, 2014-11-19](https://ferd.ca/queues-don-t-fix-overload.html)). Effect, Pony, and Akka Streams show backpressure inside one runtime. In JavaScript, backpressure holds only if callers await `send`. The repository's lint preset already turns an ignored promise into an error, and Buoy should ship the same rule for user code. `dropOldest` suits progress and state-sync messages, where only the latest value matters.

**Risk.** Backpressure can deadlock a cycle of full mailboxes. A sender that waits on a full mailbox is a wait-for edge, so the Q1 cycle detector must include these edges.

### Q6. Cancellation across actor calls

| Behavior                               | Systems                                                                    |
| -------------------------------------- | -------------------------------------------------------------------------- |
| Timeout on the caller only             | Akka `ask`, Erlang `gen_server:call` (late replies discarded since OTP 24) |
| Cooperative token passed to the callee | Orleans 9+, Ray, Swift (the caller's task)                                 |
| Structured and recursive               | Effect fibers, Temporal cancellation scopes, Restate call trees            |
| Between steps only                     | Inngest                                                                    |

**Recommendation.**

1. Every `ask` carries a cancellation signal and a deadline. Inside Buoy they are an `AbortSignal`, so npm code accepts them.
2. Cancellation is structured. A turn owns the asks it starts. Cancelling the turn cancels its outstanding asks, recursively, across actors.
3. A cancelled request still in a mailbox is removed and never starts (Orleans).
4. A request in progress sees cancellation cooperatively, at `await` points and through its signal. The runtime never interrupts synchronous code.
5. A caller's timeout cancels the callee, like Orleans with `CancelRequestOnTimeout`.
6. Deadlines propagate as remaining time. gRPC "converts the deadline to a timeout from which the already elapsed time is already deducted" ([gRPC deadlines](https://grpc.io/docs/guides/deadlines/)).
7. `tell` is detached from the sender's cancellation, as Restate detaches one-way sends.
8. Cleanup code can shield itself from cancellation, like a Temporal `nonCancellable` scope.
9. `Cancelled` is a typed outcome, separate from failure.

**Evidence.** A.1, case 5, shows queued removal and cooperative abort with a 38-line actor class. A.4 shows that `ai@7.0.142` passes the caller's signal to the model call. After the abort, the `textStream` loop ended without an exception. Buoy's wrappers must check `signal.aborted` and report `Cancelled`, or an aborted generation looks like a short success.

### Q7. Marking values that may cross an actor boundary

| Approach                              | Systems                                                |
| ------------------------------------- | ------------------------------------------------------ |
| Compile-time sendability              | Swift `Sendable` and `sending`, Pony `iso`/`val`/`tag` |
| Copy by default, opt-out by promise   | Orleans deep copy with `[Immutable]`                   |
| Structured clone, stubs, and transfer | Workers RPC, Node `postMessage`                        |

TypeScript cannot prove immutability. `readonly` only means "the property itself can't be re-written to", and "`readonly` properties can also change via aliasing" ([TypeScript handbook](https://www.typescriptlang.org/docs/handbook/2/objects.html#readonly-properties)). Structured clone throws on functions and skips the prototype chain ([MDN](https://developer.mozilla.org/en-US/docs/Web/API/Web_Workers_API/Structured_clone_algorithm)). A.6 adds that freezing cannot protect `Date`, `Map`, or typed arrays.

**Recommendation.**

1. The Buoy checker requires a `Sendable` type for every actor method parameter, result, stream element, and message.
2. `Sendable` covers structured-cloneable data, `ActorRef<P>`, and `Transfer<T>`. It excludes functions, class instances, promises, symbols, and objects with accessors or private fields.
3. The runtime copies on send in every placement, so a send never creates an alias. This matches Erlang and Orleans, and it keeps options C and D1 identical.
4. `Frozen<T>` is the zero-copy path. It accepts plain objects, arrays, and primitives only. The runtime freezes the value at every level on send and passes it by reference inside one isolate. Orleans `[Immutable]` is the precedent.
5. `Transfer<T>` moves an `ArrayBuffer` or a Web stream. The sender's binding becomes unusable, as with Node transfer lists and Workers RPC streams. The checker flags later use of a transferred binding in the same function, a narrow form of Swift's `sending`.
6. The checker flags module-level mutable state in actor code, following SE-0412 for Swift globals. npm module state remains per isolate. Buoy documents this limit, following Durable Objects.

**Evidence.** Swift needed `Sendable` plus region analysis (SE-0414, SE-0430) before any non-`Sendable` value could cross a boundary. Pony needed six reference capabilities for the same goal. Buoy's checker would need region analysis to match Swift. Until it has one, a copy is the safe default and `Frozen<T>` is the narrow exception. The cost of copying large messages, such as a conversation history, belongs in `bench/`.

Closures never cross. Workers RPC turns a function into a stub that calls back to the sender, and stub lifetimes then need explicit disposal with `using`. Buoy v1 sends an `ActorRef` instead, so a callback becomes a message to an actor.

### Q8. Streaming results across a boundary with backpressure

| Mechanism                              | Systems                                                                                      |
| -------------------------------------- | -------------------------------------------------------------------------------------------- |
| Demand signalling                      | Akka Streams (Reactive Streams), Akka StreamRefs (cumulative demand), Akka reliable delivery |
| Batched pull, scoped to one call       | Orleans `IAsyncEnumerable<T>` (default batch 100)                                            |
| Transferable streams with flow control | Workers RPC `ReadableStream`                                                                 |
| Eager, no backpressure                 | Ray generators                                                                               |

**Recommendation.**

1. A method may return `AsyncIterable<T>`, where `T` is `Sendable`. The caller receives an object that is both an `AsyncIterable<T>` and a `ReadableStream<T>`. The `ai` SDK uses the same shape: `AsyncIterableStream<T> = AsyncIterable<T> & ReadableStream<T>` in `ai@7.0.142`.
2. The runtime advances the producer only when the consumer has outstanding demand. Across isolates it grants credit in batches, as Orleans batches and Akka sends cumulative demand. A benchmark sets the batch size.
3. A stream belongs to its call. It holds the producer's turn until it completes, consistent with Q1, and `interleave` control messages still enter.
4. A consumer `break`, a `return()`, the call's cancellation, or its deadline cancels the producer at its next `await` or `yield`.
5. A producer error ends the stream with that error, after the elements already delivered. Orleans keeps such partial results. A defect also follows the Q2 path.
6. A stream has one consumer and one use, like Akka's "single-shot" `SinkRef`. Fan-out goes through a topic actor with an explicit overflow policy, usually `dropOldest` for progress updates.
7. Byte streams cross isolates by transfer.

**Evidence.** Async generators advance only on `next()` (A.6), so demand-driven pulling needs no extra protocol inside one isolate. A.5 shows that `ai@7.0.142` keeps model pulls bounded under a slow reader. A demand-driven Buoy stream on top of it therefore keeps the provider stream bounded too. Ray's eager generators show the failure mode of a stream without demand.

**Unverified.** Whether an Orleans `IAsyncEnumerable` holds the grain's turn between batches. The Orleans source for `IAsyncEnumerableGrainExtension` would settle it.

## Scores for options C and D1

Scale: 1 to 5, where 5 is best for Buoy. For "Implementation complexity", 5 means the least complex. This track scores only criteria 2, 3, 7, 8, and 9, and only where actor-system evidence supports a score. Option C hosts many lightweight actors in one isolate of Node, Deno, or Bun. Option D1 is a Node host with a pool of worker-thread schedulers, each hosting many lightweight actors.

| Option | Criterion                             | Score | Rationale                                                                                                                                                                                                                              | Evidence                                                                                                                                           |
| ------ | ------------------------------------- | ----- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| C      | Runtime isolation and fault tolerance | 2     | Supervision and restart fit in one isolate. `AsyncLocalStorage` attributes stray async errors to the right actor. An OOM, a synchronous loop, or a native crash still takes down every actor in the isolate.                           | A.3; comedy: in-memory failure means "the whole process has failed"; Node docs on a blocked event loop; Durable Objects measure memory per isolate |
| C      | Scheduling fairness                   | 2     | One event loop serves all actors. Fairness exists only at `await` and turn boundaries. The BEAM preempts by reduction count.                                                                                                           | Node: "The fair treatment of clients is thus the responsibility of your application"; Orleans TR §3.6; `CONTEXT_REDS 4000` in OTP                  |
| C      | Implementation complexity             | 4     | The recommended semantics need few platform features: `AsyncLocalStorage`, `AbortSignal`, and promises. Effect 4 already provides bounded queues with the three strategies, fiber supervision, and cluster entities.                   | A.1 (38-line actor class); Effect `Queue.ts` and `entityManager.ts`                                                                                |
| C      | Debuggability and tooling             | 4     | One isolate gives one inspector session and one heap snapshot. Error listeners can attribute errors to actors. Actor-level views, such as mailbox depth and turn duration, still need building, as Orleans long-turn monitoring shows. | A.3; Orleans TR §3.6; Effect cluster spans tag `entity.type` and `entity.id`                                                                       |
| C      | Long-term extensibility               | 3     | The recommended semantics avoid aliasing and synchronous calls, so C can grow into D1 or a multi-node runtime. One isolate uses one core, so growth requires a placement change.                                                       | Orleans grain references; Swift distributed actors written "as-if it was remote"                                                                   |
| D1     | Runtime isolation and fault tolerance | 3     | A worker contains heap exhaustion and runaway loops, measured. A worker restart loses every actor on it. A native crash or a global OOM still takes down the process.                                                                  | A.3; Node: "the process may still abort if it encounters a global out-of-memory situation"                                                         |
| D1     | Scheduling fairness                   | 3     | Several event loops divide the cores, so a hog delays only its own worker. Actors cannot move between isolates without serialization, so placement happens once. Pony and Akka steal across threads in one heap.                       | Pony scheduler docs; Akka dispatcher `throughput`; Temporal balances workflows across threads at the first activation                              |
| D1     | Implementation complexity             | 2     | D1 adds cross-isolate copy and transfer, chain and cancellation headers on every message, placement, and per-worker supervision. Temporal needed a thread pool and V8 context reuse for the same model.                                | Dapr `Dapr-Reentrancy-Id`; Temporal `WorkerOptions`; Node transfer lists                                                                           |
| D1     | Debuggability and tooling             | 3     | Each worker is a separate isolate and inspector target. Temporal turns its worker-thread pool off in `debugMode`.                                                                                                                      | Temporal `workflowThreadPoolSize` docs                                                                                                             |
| D1     | Long-term extensibility               | 4     | D1 contains C and already crosses an isolate boundary with copied messages. That boundary is the one a multi-node runtime needs.                                                                                                       | Temporal TypeScript SDK threading model; Orleans and Swift location transparency                                                                   |

## Durability lessons

The requirement reads "long-running and eventually durable". The systems above suggest these rules.

1. Two durability styles exist. Code replay (Temporal workflows, Inngest steps) requires code between journaled steps that tolerates replay. State checkpoints with journaled side effects (Orleans `WriteStateAsync`, Durable Objects storage with output gates, Effect cluster persisted messages) leave ordinary code free.
2. The checkpoint style fits Buoy actors. Turns are already serial, and a turn's end is a natural commit point.
3. Output gates matter most. A turn's replies and outgoing messages wait until its state write is durable. Without the gate, a crash after a reply and before the write leaves a reply about state that no longer exists ([Durable Objects blog](https://blog.cloudflare.com/durable-objects-easy-fast-correct-choose-three/)).
4. LLM and tool calls are slow and nondeterministic. A durable actor journals their results, so recovery never repeats them. Inngest returns "saved step results", and Temporal puts "LLM/AI invocations" in activities.
5. Timers split into volatile timers and durable reminders (Orleans, Dapr).
6. An idle actor deactivates and reactivates on demand (Orleans, Dapr, Effect cluster). The JavaScript collector cannot reclaim an actor that the runtime registry references, so lifetime must come from an explicit stop or an idle timeout.
7. Retried delivery voids FIFO and at-most-once (Orleans, Ray). Durable mailboxes need sequence numbers and idempotent methods (Akka reliable delivery, Effect cluster).

## Unverified claims and how to settle them

1. Ray keeps an actor alive with its state after an application exception. Test: call a Ray actor method that raises, then read its state.
2. Node `MessagePort` delivers messages between two workers in send order. Test: send numbered messages between two workers.
3. The per-call cost of chain tracking, wait-for cycle detection, copy on send, and recursive freezing. Test: benchmarks in `bench/`.
4. A TypeScript checker can enforce `Sendable`, `Frozen<T>`, read-only `interleave` methods, and use-after-transfer without excessive false positives. Test: a prototype in `packages/checker` against the `examples/` agents.
5. Orleans `IAsyncEnumerable` holds or releases the grain's turn between batches. Test: read the `IAsyncEnumerableGrainExtension` source.
6. A native addon crash in one worker terminates the whole Node process. Test: a worker that loads an addon which calls `abort()`.

## Appendix A: scripts

Run each Node script with `node <path>` on Node v25.9.0. The `ai` checks import `ai@7.0.142` from this repository's `node_modules/.pnpm` store by absolute path. Change `aiRoot` for another checkout.

### A.1 Turn semantics (`/tmp/buoy-actor-research/node/semantics.mjs`)

```js
// Semantics check for Buoy research (docs/research/actor-models.md). Not a benchmark.
import { AsyncLocalStorage } from "node:async_hooks";
import { setTimeout as sleep } from "node:timers/promises";

const callChain = new AsyncLocalStorage();
let nextChainId = 0;
// A referenced timer, so a deadlocked program waits for the deadline instead of exiting.
const deadline = (ms) => {
  const controller = new AbortController();
  setTimeout(() => controller.abort(new Error(`deadline ${ms} ms exceeded`)), ms);
  return controller.signal;
};

class TurnActor {
  #queue = [];
  #runningChain = undefined;
  constructor(name, behavior, { callChainReentrancy = false } = {}) {
    this.name = name;
    this.behavior = behavior;
    this.callChainReentrancy = callChainReentrancy;
  }
  ask(method, args = [], signal = deadline(300)) {
    const chain = callChain.getStore() ?? ++nextChainId;
    return new Promise((resolve, reject) => {
      const request = { method, args, chain, signal, resolve, reject };
      signal.addEventListener("abort", () => this.#dropQueued(request), { once: true });
      if (this.callChainReentrancy && chain === this.#runningChain) return this.#invoke(request);
      this.#queue.push(request);
      this.#drain();
    });
  }
  #dropQueued(request) {
    const index = this.#queue.indexOf(request);
    if (index < 0) return;
    this.#queue.splice(index, 1);
    request.reject(new Error(`${this.name}.${request.method}: cancelled while queued`));
  }
  #invoke(request) {
    const run = () => this.behavior[request.method](request.signal, ...request.args);
    return callChain.run(request.chain, run).then(request.resolve, request.reject);
  }
  async #drain() {
    if (this.#runningChain !== undefined) return;
    while (this.#queue.length > 0) {
      const request = this.#queue.shift();
      this.#runningChain = request.chain;
      await this.#invoke(request);
    }
    this.#runningChain = undefined;
  }
}

const settle = (promise) =>
  promise.then(
    (value) => `ok:${value}`,
    (error) => `error:${error.message}`,
  );

const naive = {
  value: 0,
  async increment() {
    const seen = this.value;
    await sleep(10);
    this.value = seen + 1;
  },
};
await Promise.all([naive.increment(), naive.increment()]);
console.log("1 naive async object, two increments ->", naive.value);

const counterState = { value: 0 };
const counter = new TurnActor("counter", {
  async increment() {
    const seen = counterState.value;
    await sleep(10);
    counterState.value = seen + 1;
    return counterState.value;
  },
});
await Promise.all([counter.ask("increment"), counter.ask("increment")]);
console.log("2 turn-based actor, two increments ->", counterState.value);

const makePair = (callChainReentrancy) => {
  const user = new TurnActor(
    "user",
    {
      async joinRoom(signal) {
        return room.ask("onJoin", [], signal);
      },
      async displayName() {
        return "ada";
      },
    },
    { callChainReentrancy },
  );
  const room = new TurnActor(
    "room",
    {
      async onJoin(signal) {
        return `joined:${await user.ask("displayName", [], signal)}`;
      },
    },
    { callChainReentrancy },
  );
  return user;
};
console.log("3 turn-based, callback cycle ->", await settle(makePair(false).ask("joinRoom")));
console.log(
  "4 call-chain reentrancy, callback cycle ->",
  await settle(makePair(true).ask("joinRoom")),
);

const model = new TurnActor("model", {
  async generate(signal) {
    await sleep(1000, undefined, { signal });
    return "text";
  },
});
const caller = new AbortController();
const running = settle(model.ask("generate", [], caller.signal));
const queued = settle(model.ask("generate", [], caller.signal));
setTimeout(() => caller.abort(new Error("caller cancelled")), 50);
console.log("5 running request ->", await running);
console.log("5 queued request ->", await queued);
console.log("node", process.version);
```

Output:

```text
1 naive async object, two increments -> 1
2 turn-based actor, two increments -> 2
3 turn-based, callback cycle -> error:user.displayName: cancelled while queued
4 call-chain reentrancy, callback cycle -> ok:joined:ada
5 running request -> error:The operation was aborted
5 queued request -> error:model.generate: cancelled while queued
node v25.9.0
```

### A.2 Erlang restart identity (`/tmp/buoy-actor-research/erlang/restart_demo.erl`)

Command:

```sh
mkdir -p /tmp/buoy-actor-research/erlang/build
docker run --rm \
  -v /tmp/buoy-actor-research/erlang/restart_demo.erl:/src/restart_demo.erl:ro \
  -v /tmp/buoy-actor-research/erlang/build:/build \
  erlang:29.1.2 sh -c 'cd /build && erlc /src/restart_demo.erl && erl -noshell -pa /build -s restart_demo main'
```

```erlang
-module(restart_demo).
-behaviour(supervisor).
-export([main/0, init/1, worker_start/0]).

init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [#{id => worker, start => {?MODULE, worker_start, []}}]}}.

worker_start() ->
    Pid = spawn_link(fun() -> loop([]) end),
    register(worker, Pid),
    {ok, Pid}.

loop(Seen) ->
    receive
        {block, From} ->
            From ! blocked,
            %% Selective receive: queued {msg, N} messages stay in the mailbox.
            receive crash_now -> exit(deliberate_crash) end;
        {msg, N} ->
            loop([N | Seen]);
        {report, From} ->
            From ! {seen, lists:reverse(Seen)},
            loop(Seen)
    end.

main() ->
    process_flag(trap_exit, true),
    {ok, _Sup} = supervisor:start_link({local, demo_sup}, ?MODULE, []),
    Old = whereis(worker),
    Old ! {block, self()},
    receive blocked -> ok end,
    [Old ! {msg, N} || N <- [1, 2, 3]],
    {message_queue_len, QueuedAtCrash} = process_info(Old, message_queue_len),
    Old ! crash_now,
    timer:sleep(200),
    New = whereis(worker),
    New ! {report, self()},
    Seen = receive {seen, S} -> S after 1000 -> timeout end,
    Old ! {msg, 4},
    io:format("old_pid=~p new_pid=~p same_pid=~p~n", [Old, New, Old =:= New]),
    io:format("queued_in_old_mailbox_at_crash=~p~n", [QueuedAtCrash]),
    io:format("messages_seen_by_new_incarnation=~p~n", [Seen]),
    io:format("old_pid_alive=~p send_to_old_pid_returned_normally=true~n", [is_process_alive(Old)]),
    io:format("otp_release=~s~n", [erlang:system_info(otp_release)]),
    init:stop().
```

Output (after the supervisor's crash report):

```text
old_pid=<0.84.0> new_pid=<0.85.0> same_pid=false
queued_in_old_mailbox_at_crash=3
messages_seen_by_new_incarnation=[]
old_pid_alive=false send_to_old_pid_returned_normally=true
otp_release=29
```

### A.3 Isolation (`/tmp/buoy-actor-research/node/isolation.mjs`)

```js
import { AsyncLocalStorage } from "node:async_hooks";
import { Worker } from "node:worker_threads";

const runWorker = async (label, source, options = {}) => {
  const worker = new Worker(source, { eval: true, ...options });
  worker.on("error", (error) =>
    console.log(`${label}: worker error event -> ${error.code ?? error.name}`),
  );
  setTimeout(() => worker.terminate(), 500).unref();
  // events.once would reject on the "error" event, so wait for "exit" only.
  const exitCode = await new Promise((resolve) => worker.on("exit", resolve));
  console.log(`${label}: worker exit code ${exitCode}; main thread still running`);
};

await runWorker("oom", "const keep = []; for (;;) keep.push(new Array(1e5).fill(Math.random()));", {
  resourceLimits: { maxOldGenerationSizeMb: 32 },
});
await runWorker("busy-loop", "for (;;) {}");

const currentActor = new AsyncLocalStorage();
process.on("uncaughtException", (error) =>
  console.log(`stray error from actor=${currentActor.getStore()}: ${error.message}`),
);
process.on("unhandledRejection", (reason) =>
  console.log(`stray rejection from actor=${currentActor.getStore()}: ${reason.message}`),
);
currentActor.run("planner", () =>
  setTimeout(() => {
    throw new Error("tool callback failed");
  }, 10),
);
currentActor.run("critic", () => {
  Promise.reject(new Error("floating promise rejected"));
});
await new Promise((resolve) => setTimeout(resolve, 50));
console.log("node", process.version);
```

Output:

```text
oom: worker error event -> ERR_WORKER_OUT_OF_MEMORY
oom: worker exit code 1; main thread still running
busy-loop: worker exit code 1; main thread still running
stray rejection from actor=critic: floating promise rejected
stray error from actor=planner: tool callback failed
node v25.9.0
```

### A.4 `ai` abort propagation (`/tmp/buoy-actor-research/node/ai-abort.mjs`)

```js
const aiRoot =
  "/Users/joshgalbreath/Code/buoy/node_modules/.pnpm/ai@7.0.142_zod@4.6.7/node_modules/ai";
const { streamText } = await import(`${aiRoot}/dist/index.js`);
const { MockLanguageModelV4 } = await import(`${aiRoot}/dist/test/index.js`);

let modelSignal;
const model = new MockLanguageModelV4({
  doStream: async (options) => {
    modelSignal = options.abortSignal;
    let index = 0;
    return {
      stream: new ReadableStream({
        start(controller) {
          controller.enqueue({ type: "stream-start", warnings: [] });
          controller.enqueue({ type: "text-start", id: "t" });
        },
        async pull(controller) {
          await new Promise((resolve) => setTimeout(resolve, 20));
          controller.enqueue({ type: "text-delta", id: "t", delta: `token${index++} ` });
        },
      }),
    };
  },
});

const caller = new AbortController();
const result = streamText({ model, prompt: "hi", abortSignal: caller.signal });
const received = [];
try {
  for await (const text of result.textStream) {
    received.push(text);
    if (received.length === 2) caller.abort(new Error("caller cancelled"));
  }
  console.log("loop ended normally");
} catch (error) {
  console.log("loop threw:", error?.name, error?.message);
}
console.log("chunks received:", received.length);
console.log(
  "signal passed to model is the caller-linked signal and is aborted:",
  modelSignal?.aborted,
);
console.log("textStream is a ReadableStream:", result.textStream instanceof ReadableStream);
console.log("node", process.version);
```

Output:

```text
loop ended normally
chunks received: 2
signal passed to model is the caller-linked signal and is aborted: true
textStream is a ReadableStream: true
node v25.9.0
```

### A.5 `ai` backpressure (`/tmp/buoy-actor-research/node/ai-backpressure.mjs`)

```js
const aiRoot =
  "/Users/joshgalbreath/Code/buoy/node_modules/.pnpm/ai@7.0.142_zod@4.6.7/node_modules/ai";
const { streamText } = await import(`${aiRoot}/dist/index.js`);
const { MockLanguageModelV4 } = await import(`${aiRoot}/dist/test/index.js`);

const totalChunks = 200;
let pulled = 0;
const model = new MockLanguageModelV4({
  doStream: async () => ({
    stream: new ReadableStream({
      start(controller) {
        controller.enqueue({ type: "stream-start", warnings: [] });
        controller.enqueue({ type: "text-start", id: "t" });
      },
      pull(controller) {
        if (pulled === totalChunks) {
          controller.enqueue({ type: "text-end", id: "t" });
          controller.enqueue({
            type: "finish",
            finishReason: { unified: "stop", raw: "stop" },
            usage: {
              inputTokens: { total: 1, noCache: 1, cacheRead: 0, cacheWrite: 0 },
              outputTokens: { total: totalChunks, text: totalChunks, reasoning: 0 },
            },
          });
          controller.close();
          return;
        }
        pulled += 1;
        controller.enqueue({ type: "text-delta", id: "t", delta: "x" });
      },
    }),
  }),
});

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const result = streamText({ model, prompt: "hi" });
const reader = result.textStream.getReader();
for (let consumed = 1; consumed <= 3; consumed += 1) {
  await reader.read();
  await sleep(100);
  console.log(
    `consumer read ${consumed} chunk(s); model stream pulled ${pulled} of ${totalChunks}`,
  );
}
await reader.cancel();
console.log("node", process.version);
```

Output (identical on two runs):

```text
consumer read 1 chunk(s); model stream pulled 18 of 200
consumer read 2 chunk(s); model stream pulled 19 of 200
consumer read 3 chunk(s); model stream pulled 20 of 200
node v25.9.0
```

### A.6 Freeze, clone, and generator checks (`/tmp/buoy-actor-research/node/checks.mjs`)

```js
const d = Object.freeze(new Date(0));
d.setTime(86400000);
console.log("frozen Date after setTime:", d.toISOString());
const m = Object.freeze(new Map());
m.set("k", 1);
console.log("frozen Map size after set:", m.size);
try {
  Object.freeze(new Uint8Array(4));
  console.log("froze typed array");
} catch (e) {
  console.log("freeze typed array ->", e.constructor.name + ": " + e.message);
}
const o = Object.freeze({ a: { b: 1 } });
o.a.b = 2;
console.log("shallow freeze nested write:", o.a.b);
try {
  structuredClone({ f() {} });
} catch (e) {
  console.log("structuredClone function ->", e.name);
}
class C {
  #x = 1;
  get x() {
    return this.#x;
  }
}
const c = structuredClone(new C());
console.log(
  "structuredClone class instance -> prototype is Object.prototype:",
  Object.getPrototypeOf(c) === Object.prototype,
  "keys:",
  JSON.stringify(Object.keys(c)),
);
try {
  structuredClone(Symbol("s"));
} catch (e) {
  console.log("structuredClone symbol ->", e.name);
}
let produced = 0;
async function* tokens() {
  for (;;) {
    produced += 1;
    yield produced;
  }
}
const it = tokens();
await it.next();
await it.next();
await new Promise((r) => setTimeout(r, 50));
console.log("async generator produced", produced, "values after 2 next() calls and a 50 ms wait");
await it.return();
```

Output:

```text
frozen Date after setTime: 1970-01-02T00:00:00.000Z
frozen Map size after set: 1
freeze typed array -> TypeError: Cannot freeze array buffer views with elements
shallow freeze nested write: 2
structuredClone function -> DataCloneError
structuredClone class instance -> prototype is Object.prototype: true keys: []
structuredClone symbol -> DataCloneError
async generator produced 2 values after 2 next() calls and a 50 ms wait
```

## Recommended semantics for Buoy

These rules hold in every placement. No rule depends on whether two actors sit in one isolate, except that npm module state and memory limits are per isolate.

| Area               | Semantics                                                                                                                                                                                                                  | Default                                                                       |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Identity           | `ActorRef<P>` is a stable logical address. It survives restarts and dies only when the actor stops.                                                                                                                        |                                                                               |
| Turns              | An actor serves one request at a time. A request holds the actor until its promise settles, across every `await`.                                                                                                          | Turn-based                                                                    |
| Reentrancy         | A request in the call chain of the waiting turn enters at once. `interleave` methods (read-only queries, control) may enter while a turn waits.                                                                            | Call-chain reentrancy on                                                      |
| Deadlock           | A wait-for cycle inside one isolate fails the closing call with `Deadlock`. Across isolates, deadlines end the cycle.                                                                                                      | On                                                                            |
| Failure            | A declared error, returned as a value, rejects the caller only. An exception is a defect. The caller gets `ActorDefect`, the runtime discards state, and the supervisor decides.                                           | Restart with backoff under an intensity limit, then stop and escalate         |
| Restart            | The mailbox stays. The failing message is dropped. Watchers get `Restarted { incarnation }`.                                                                                                                               |                                                                               |
| Ordering           | FIFO per sender and receiver for user messages. Control messages may overtake. No causal order.                                                                                                                            |                                                                               |
| Delivery           | At-most-once in memory. The durable mode adds at-least-once with sequence numbers and idempotency keys.                                                                                                                    | At-most-once                                                                  |
| Mailbox            | Always bounded. Policies: `backpressure`, `fail`, `dropNewest`, `dropOldest`. Control messages bypass the bound.                                                                                                           | `backpressure` inside the runtime, `fail` at the edge, capacity from `bench/` |
| Cancellation       | Each `ask` carries an `AbortSignal` and a deadline. Cancellation is structured, recursive, and cooperative. Queued requests are removed. A timeout cancels the callee. `tell` is detached. `Cancelled` is a typed outcome. |                                                                               |
| Sendable           | The checker enforces `Sendable` on every boundary type. `Frozen<T>` passes plain data by reference inside one isolate. `Transfer<T>` moves buffers and streams.                                                            | Copy on send                                                                  |
| Streams            | A method may return `AsyncIterable<T>`, received as `AsyncIterable<T> & ReadableStream<T>`. Pulls follow demand, credit moves in batches across isolates, the stream is bound to its call, and it has one consumer.        |                                                                               |
| Lifetime           | An actor ends by an explicit stop or an idle timeout. Garbage collection never ends a live actor.                                                                                                                          | Idle timeout configurable                                                     |
| Durability (later) | A turn's state is checkpointed at its end, behind an output gate. LLM and tool results are journaled. Reminders are durable, and timers are not.                                                                           |                                                                               |

### How the rules cover the required concerns

| Concern                   | Rule                                                                                                                                                                                                         |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Closures                  | Functions are not `Sendable`. A callback crosses as an `ActorRef`.                                                                                                                                           |
| Mutable objects           | Copy on send. `Frozen<T>` freezes plain data before passing it by reference.                                                                                                                                 |
| Promises                  | A turn ends when the method's promise settles. A floating promise that rejects is a defect of its actor, and the lint rule `no-floating-promises` catches most of them.                                      |
| Event loops               | Fairness exists only at `await` and turn boundaries. Status and cancel use `interleave` methods, so a turn that waits on I/O cannot block them.                                                              |
| Native npm modules        | A native crash ends every actor in the process, in C and in D1 (unverified for D1, item 6).                                                                                                                  |
| Node APIs                 | npm and Node module state is per isolate. `AbortSignal` carries cancellation into `fetch` ([MDN `RequestInit.signal`](https://developer.mozilla.org/en-US/docs/Web/API/RequestInit)) and the `ai` SDK (A.4). |
| Async I/O                 | I/O awaits stay inside the turn. Cancellation reaches I/O through the signal.                                                                                                                                |
| Garbage collection        | An actor ends by stop or idle timeout. The collector reclaims its state after that.                                                                                                                          |
| Cross-actor communication | Per-pair FIFO, at-most-once in memory, bounded mailboxes, typed outcomes (`ActorDefect`, `ActorStopped`, `Deadlock`, `Overloaded`, `Cancelled`).                                                             |
