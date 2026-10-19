# Example set

Status: design, 2026-10-16. Nothing here is built. The examples land when the engine runs them; each one gets an end-to-end test against the fake OpenAI server.

The owner asked for examples that draw on the best agent and actor examples online. Four surveys read the Anthropic and OpenAI agent guides and cookbooks, the AI SDK docs, Erlang/OTP, Akka, and Orleans showcases, Effect idioms, and LangGraph, CrewAI, AutoGen, Swarm, and Temporal samples. A designer chose these 13, and a second pass rewrote them for the goal that every npm package runs unchanged.

Each example says what BEAM does better than the Node event loop.

## Reading order

| #   | Example                                                                                             | Level        | Shows                                                                                                                                                 |
| --- | --------------------------------------------------------------------------------------------------- | ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | [Let it crash: an outcome keeps state, a crash restarts the actor](#let-it-crash)                   | starter      | spawn(Class, { name, args }) and a ref that keeps working after a restart                                                                             |
| 2   | [Adopt one class: unchanged Node code becomes an actor](#adopt-one-class)                           | starter      | A Node-style class runs unchanged in an actor: extends EventEmitter, a getter, a protected field, #private, a regex with named groups, setInterval    |
| 3   | [Translation desk: agents as tools, with one crashing translator](#translation-desk)                | starter      | generateText with tools whose execute awaits an actor ref; the ai package runs the tool calls of one step concurrently                                |
| 4   | [Runaway job: one loop cannot freeze the system](#runaway-job)                                      | intermediate | BEAM preemption: a CPU-bound actor does not delay a 50 ms setInterval in another actor                                                                |
| 5   | [Code review panel: a CPU-heavy tool does not stall the other agents](#code-review-panel)           | intermediate | Reviewer actors under supervise(), asked at once with Effect.all over a record and concurrency "unbounded"                                            |
| 6   | [Overload: a deep queue, backpressure, or load shedding](#overload)                                 | intermediate | mailbox: { capacity, overflow: "backpressure"                                                                                                         | "reject" } on spawn |
| 7   | [The band: supervision strategies and restart budgets](#the-band)                                   | intermediate | supervise() with one-for-one, rest-for-one, and one-for-all                                                                                           |
| 8   | [Hedged answer: race a backup agent and stop the loser](#hedged-answer)                             | intermediate | Effect.race between two scoped actors: the loser's finalizer stops its actor                                                                          |
| 9   | [Guardrail tripwire: stop the agent inside its refund tool](#guardrail-tripwire)                    | intermediate | Effect.all with concurrency: the first failure interrupts the sibling, and its scope stops the agent actor                                            |
| 10  | [Ticket lanes: one bounded lane per tenant, retry then fall back](#ticket-lanes)                    | advanced     | One actor per tenant with mailbox { capacity: 4, overflow: "reject" }                                                                                 |
| 11  | [Research lead: a stuck researcher cannot hold up the report](#research-lead)                       | advanced     | Effect.forEach with concurrency 3 caps the fan-out                                                                                                    |
| 12  | [Airline support desk: one actor per conversation, handoffs, and a crashing backend](#support-desk) | advanced     | One Session actor per conversation keeps the history and the active agent; a turn spans the awaits of send(), so a second message waits for the first |
| 13  | [Subagent team: a lead agent that spawns, waits for, and stops helpers](#subagent-team)             | advanced     | A lead agent whose tools spawn, inspect, and stop actors                                                                                              |

## let-it-crash

**Let it crash: an outcome keeps state, a crash restarts the actor** (starter)

A Stock actor counts apples and writes each change to a Journal actor. A request to reserve 5 apples when 1 is left returns OutOfStock, a Data.TaggedEnum value, and Stock keeps its count. A restock of -1 is a bug, so the method throws. The caller's promise rejects with ActorFailed, Buoy restarts Stock under the same ref with a new instance, and the new instance replays the journal, so the next restock answers 2 and not 1. Why BEAM: the throw ends one process, and the runtime rebuilds it under the same ref. In Node the throw only rejects one promise: the shared object keeps whatever state the method reached, and nothing rebuilds it.

Shows:

- spawn(Class, { name, args }) and a ref that keeps working after a restart
- A ref call returns a promise of a copy of the reply; Effect.tryPromise turns a rejection into a typed StockCrashed error
- Expected results as data: a Data.TaggedEnum outcome crosses the actor boundary as a plain object, and $match reads its _tag
- A thrown error is a crash: the caller gets ActorFailed, stderr gets one crash line, and the actor restarts
- A restart builds a new instance, so the count comes back from a Journal actor
- inspect() rows with status and restart counts

Needs from the engine:

- Ref calls as promises: a call sends a copy of the arguments and returns a promise of a copy of the reply, and replies from other actors arrive while a turn awaits (spike: buoy_jobs actor_call; not in main)
- A turn lasts until the method's promise settles, and the next call waits (spike)
- A throw or a rejected method promise crashes the actor: ActorFailed to the caller, one stderr line, and a restart under the same ref with the original arguments (subset runtime; port to the new engine)
- Message copies keep a ref as a ref and turn a Data.TaggedEnum value into a plain object with _tag (planned)
- The real effect 4.0.5 from node_modules: Data.taggedEnum, Data.TaggedError, Effect.tryPromise, Effect.catchTag (planned)
- inspect() (subset runtime; port)

LLM: none

Inspired by:

- <https://effect.website/docs/v4/error-management/two-error-types.md>
- <https://www.erlang.org/doc/system/sup_princ.html>
- <https://learnyousomeerlang.com/errors-and-processes>
- <https://doc.akka.io/libraries/akka-core/current/typed/persistence-style.html>
- <https://elixirforum.com/t/building-an-ai-agent-runtime-moving-from-typescript-to-elixir-otp-can-you-help-compare-notes/76384>

Files: `examples/let-it-crash/main.ts`, `examples/let-it-crash/expected.stdout`, `examples/let-it-crash/expected.stderr`

Sketch:

```ts
// An outcome keeps an actor's state. A thrown error crashes the actor, and
// Buoy restarts it under the same ref with a new instance. The new instance
// replays a journal, so the restart loses no stock.
import { Console, Data, Effect } from "effect";
import { inspect, spawn, type Ref } from "buoy";

type Reservation = Data.TaggedEnum<{
  Reserved: { readonly left: number };
  OutOfStock: { readonly left: number };
}>;
const Reservation = Data.taggedEnum<Reservation>();

class StockCrashed extends Data.TaggedError("StockCrashed")<{ readonly reason: unknown }> {}

class Journal {
  #changes: number[] = [];

  append(change: number): void {
    this.#changes.push(change);
  }

  changes(): number[] {
    return this.#changes;
  }
}

class Stock {
  #count: number | undefined;
  readonly #journal: Ref<Journal>;

  constructor(journal: Ref<Journal>) {
    this.#journal = journal;
  }

  async restock(amount: number): Promise<number> {
    if (amount <= 0) throw new RangeError(`restock needs a positive amount, got ${amount}`);
    return this.#record(amount);
  }

  async reserve(amount: number): Promise<Reservation> {
    const count = await this.#current();
    if (amount > count) return Reservation.OutOfStock({ left: count });
    return Reservation.Reserved({ left: await this.#record(-amount) });
  }

  // A restart builds a new instance, so the count comes back from the journal.
  async #current(): Promise<number> {
    this.#count ??= (await this.#journal.changes()).reduce((sum, change) => sum + change, 0);
    return this.#count;
  }

  async #record(change: number): Promise<number> {
    const count = await this.#current();
    await this.#journal.append(change);
    this.#count = count + change;
    return this.#count;
  }
}

const call = <A>(request: () => Promise<A>) =>
  Effect.tryPromise({ try: request, catch: (reason) => new StockCrashed({ reason }) });

const restock = (stock: Ref<Stock>, amount: number) =>
  call(() => stock.restock(amount)).pipe(Effect.map((left) => `${left} left`));

const reserve = (stock: Ref<Stock>, amount: number) =>
  call(() => stock.reserve(amount)).pipe(
    Effect.map(
      Reservation.$match({
        Reserved: ({ left }) => `${left} left`,
        OutOfStock: ({ left }) => `refused, only ${left} left`,
      }),
    ),
  );

const report = (label: string, request: Effect.Effect<string, StockCrashed>) =>
  request.pipe(
    Effect.catchTag("StockCrashed", (error) => Effect.succeed(String(error.reason))),
    Effect.flatMap((text) => Console.log(`${label}: ${text}`)),
  );

const program = Effect.gen(function* () {
  const stock = spawn(Stock, { name: "stock", args: [spawn(Journal)] });
  yield* report("restock 3", restock(stock, 3));
  yield* report("reserve 2", reserve(stock, 2));
  yield* report("reserve 5", reserve(stock, 5));
  yield* report("restock -1", restock(stock, -1));
  yield* report("restock 1", restock(stock, 1));
  for (const actor of inspect()) {
    yield* Console.log(`${actor.class}: ${actor.status}, restarts ${actor.restarts}`);
  }
});

await Effect.runPromise(program);
```

Expected output:

```text
stdout:
restock 3: 3 left
reserve 2: 1 left
reserve 5: refused, only 1 left
restock -1: ActorFailed: Stock stock failed in restock: RangeError: restock needs a positive amount, got -1
restock 1: 2 left
Journal: running, restarts 0
Stock: running, restarts 1
stderr:
buoy: Stock stock crashed: RangeError: restock needs a positive amount, got -1
exit status: 0
```

## adopt-one-class

**Adopt one class: unchanged Node code becomes an actor** (starter)

SessionStore is Node code as many services have it: it extends EventEmitter, parses session ids with a regex with named groups, has a getter, and sweeps old sessions with setInterval. It has a bug: a malformed id makes the sweep emit "error" with no listener, so emit() throws inside a timer callback. The one change for Buoy is spawn(SessionStore) in place of new SessionStore(). The bug now crashes one actor, which restarts under the same ref with an empty store, and the program goes on. Why BEAM: in Node an error in a timer callback ends the process and every request in it, so the same program with new SessionStore() stops after "sessions after the bad id: 4" with exit status 1. An actor crashes alone and comes back under the same ref.

Shows:

- A Node-style class runs unchanged in an actor: extends EventEmitter, a getter, a protected field, #private, a regex with named groups, setInterval
- Adopting an actor is a one-line change: spawn(Class, { args }) in place of new Class(...)
- An uncaught error in an actor's timer callback crashes that actor alone
- A restart loses the in-memory state: the store comes back empty, and let-it-crash shows the replay fix
- sessions.ts imports nothing from buoy

Needs from the engine:

- spawn() of any class, also a class that extends another class (new: the subset allowed only classes without extends)
- node:events EventEmitter with Node's rule that emit("error") without a listener throws the error (planned: migration plan item 3.10)
- Class inheritance, getters, protected and #private fields (spike)
- Regular expressions with named groups (planned: item 3.4)
- setInterval in an actor, and an uncaught error in a timer callback crashes that actor (spike timers; the crash rule is new)

LLM: none

Inspired by:

- <https://nodejs.org/api/events.html#error-events>
- <https://nodejs.org/api/process.html#event-uncaughtexception>
- <https://elixirforum.com/t/building-an-ai-agent-runtime-moving-from-typescript-to-elixir-otp-can-you-help-compare-notes/76384>
- <https://www.erlang.org/doc/system/sup_princ.html>

Files: `examples/adopt-one-class/main.ts`, `examples/adopt-one-class/sessions.ts`, `examples/adopt-one-class/expected.stdout`, `examples/adopt-one-class/expected.stderr`

Sketch:

```ts
// Adopt actors one class at a time. SessionStore is ordinary Node code with a
// bug in a timer callback, and in Node that bug ends the whole process. Here
// the one change is spawn(SessionStore) in place of new SessionStore(), so the
// bug crashes one actor, which restarts under the same ref, and the program
// goes on.
import { Console, Effect } from "effect";
import { inspect, spawn } from "buoy";
import { SessionStore } from "./sessions.ts";

const program = Effect.gen(function* () {
  // Before: const sessions = new SessionStore(60_000);
  const sessions = spawn(SessionStore, { name: "sessions", args: [60_000] });
  for (const id of ["ana-1", "ben-2", "carol-3"]) yield* Effect.promise(() => sessions.touch(id));
  const users = yield* Effect.promise(() => sessions.users());
  yield* Console.log(`users: ${users.join(", ")}`);

  // A client sends a malformed id. The next sweep, at most 20 ms later, throws.
  const count = yield* Effect.promise(() => sessions.touch("Bad Id!"));
  yield* Console.log(`sessions after the bad id: ${count}`);
  yield* Effect.sleep("100 millis");

  const after = yield* Effect.promise(() => sessions.users());
  yield* Console.log(`sessions after the restart: ${after.length}`);
  for (const actor of inspect()) {
    yield* Console.log(`${actor.name}: ${actor.status}, restarts ${actor.restarts}`);
  }
});

await Effect.runPromise(program);

// ===== examples/adopt-one-class/sessions.ts =====
// A session store written for Node, as many services have one. Buoy runs this
// file unchanged: it imports nothing from buoy.
import { EventEmitter } from "node:events";

const SESSION_ID = /^(?<user>[a-z]+)-(?<n>\d+)$/;

class Store<V> extends EventEmitter {
  protected readonly entries = new Map<string, V>();

  get size(): number {
    return this.entries.size;
  }
}

export class SessionStore extends Store<number> {
  readonly #ttlMs: number;

  constructor(ttlMs: number) {
    super();
    this.#ttlMs = ttlMs;
    setInterval(() => this.#sweep(), 20);
  }

  touch(id: string): number {
    this.entries.set(id, Date.now());
    return this.size;
  }

  users(): string[] {
    return [...this.entries.keys()].map((id) => SESSION_ID.exec(id)?.groups?.user ?? id);
  }

  // The bug: a malformed id makes the sweep emit "error", and no one listens,
  // so emit() throws inside a timer callback.
  #sweep(): void {
    for (const [id, seenAt] of this.entries) {
      if (!SESSION_ID.test(id)) this.emit("error", new Error(`bad session id: ${id}`));
      if (Date.now() - seenAt > this.#ttlMs) this.entries.delete(id);
    }
  }
}
```

Expected output:

```text
stdout:
users: ana, ben, carol
sessions after the bad id: 4
sessions after the restart: 0
sessions: running, restarts 1
stderr:
buoy: SessionStore sessions crashed: Error: bad session id: Bad Id!
exit status: 0
```

## translation-desk

**Translation desk: agents as tools, with one crashing translator** (starter)

A manager agent asks for "Good morning" in Spanish, French, and Italian, and calls three translator tools in one step. Each tool's execute awaits a supervised Translator actor, and each translator runs its own generateText in a fresh context. The fake model echoes its instructions, so each answer shows that its translator saw only its own system prompt. The scripted model sends an empty text to the Italian tool, as real models sometimes do. The Italian translator throws, the AI SDK turns the rejected execute into a tool-error part, and the supervisor restarts Italian, which then translates "Good night" through the same ref. Why BEAM: the AI SDK starts the tool calls of a step together, and each one works in its own supervised process, so a crash fails one tool call and a restart repairs the translator with no cleanup code.

Shows:

- generateText with tools whose execute awaits an actor ref; the ai package runs the tool calls of one step concurrently
- One Effect Schema per tool input: Schema.toStandardJSONSchemaV1(Schema.toStandardSchemaV1(...)) gives the type, the validation, and the JSON Schema
- A crash inside a tool becomes a tool-error part: "ActorFailed: Translator italian failed in translate: Error: nothing to translate"
- supervise({ strategy: "one-for-one", children }) with keys that name the actors
- The smallest CALLS script for the fake OpenAI server, kept in script.ts

Needs from the engine:

- The real ai 7.0.142 and @ai-sdk/openai 4.0.95 from node_modules, which need fetch, Headers, Response, and AbortController on BEAM (planned: item 3.8)
- Effect Schema as Standard Schema with JSON Schema: Schema.toStandardSchemaV1 and Schema.toStandardJSONSchemaV1 of effect 4.0.5 (planned with the real effect package)
- supervise and child (subset runtime; port)
- A rejected method promise crashes the actor and rejects the caller with ActorFailed, whose String() the AI SDK puts in the tool-error part (subset semantics; port)
- Module bindings per actor: each Translator's process sets up model and the ai module state that it uses (new rule)

LLM: Fake OpenAI server runtime/test/library/buoy_fake_openai.erl, with OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 and OPENAI_API_KEY=sk-fake-key. Every request goes to openai.chat(model). The server reads `CALLS <steps>` at the end of the last user message and answers step k of the turn with entry k: an array of tool calls, or a string that is the text answer (the string step is new). After the last entry it answers with text: "Results: <tool> -> <output>, ..." or "Hello! System: <system>. You said: <prompt>". Request 1 (manager): step 1 calls spanish and french with "Good morning" and italian with ""; step 2 is text. Each translator request has no tools, so the server answers "Hello! System: Translate into <language>. You said: <text>". Request 2: step 1 calls italian with "Good night".

// examples/translation-desk/script.ts
// The fake OpenAI server of the tests reads `CALLS <steps>` at the end of the
// last user message and makes those tool calls, one array per step. A real
// model decides for itself.
const scripted = (text: string, steps: unknown[]): string =>
`${text} CALLS ${JSON.stringify(steps)}`;

export const firstRequest = scripted(
'Translate "Good morning" into Spanish, French, and Italian.',
[
[
{ name: "spanish", input: { text: "Good morning" } },
{ name: "french", input: { text: "Good morning" } },
{ name: "italian", input: { text: "" } },
],
],
);

export const secondRequest = scripted('Translate "Good night" into Italian.', [
[{ name: "italian", input: { text: "Good night" } }],
]);

Inspired by:

- <https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf>
- <https://github.com/openai/openai-agents-python/blob/main/examples/agent_patterns/agents_as_tools.py>
- <https://ai-sdk.dev/docs/agents/subagents>
- <https://ai-sdk.dev/docs/ai-sdk-core/tools-and-tool-calling>

Files: `examples/translation-desk/main.ts`, `examples/translation-desk/script.ts`, `examples/translation-desk/expected.stdout`, `examples/translation-desk/expected.stderr`

Sketch:

```ts
// A manager agent calls three translator agents as tools in one step. Each
// translator is a supervised actor, so the tool calls run in parallel
// processes, the Italian crash fails one tool call, and the supervisor
// restarts that translator alone.
import { Console, Effect, Schema } from "effect";
import { child, inspect, supervise, type Ref } from "buoy";
import { generateText, isStepCount, tool, type ToolSet } from "ai";
import { openai } from "@ai-sdk/openai";
import { firstRequest, secondRequest } from "./script.ts";

const model = openai.chat("gpt-4o-mini");

// One Effect Schema gives the tool its type, its validation, and the JSON Schema that the model reads.
const TranslateInput = Schema.toStandardJSONSchemaV1(
  Schema.toStandardSchemaV1(Schema.Struct({ text: Schema.String })),
);

class Translator {
  readonly #language: string;

  constructor(language: string) {
    this.#language = language;
  }

  async translate(text: string): Promise<string> {
    if (text.length === 0) throw new Error("nothing to translate");
    const system = `Translate into ${this.#language}`;
    const reply = await generateText({ model, system, prompt: text });
    return reply.text;
  }
}

const translatorTool = (translator: Ref<Translator>) =>
  tool({
    description: "Translate a text",
    inputSchema: TranslateInput,
    execute: ({ text }) => translator.translate(text),
  });

const answer = Effect.fn("Manager.answer")(function* (tools: ToolSet, prompt: string) {
  const result = yield* Effect.tryPromise(() =>
    generateText({ model, prompt, tools, stopWhen: isStepCount(2) }),
  );
  for (const part of result.steps.flatMap((step) => step.content)) {
    if (part.type === "tool-result") yield* Console.log(`${part.toolName}: ${part.output}`);
    if (part.type === "tool-error") yield* Console.log(`${part.toolName}: ${part.error}`);
  }
});

const program = Effect.gen(function* () {
  const desk = supervise({
    strategy: "one-for-one",
    children: {
      spanish: child(Translator, { args: ["Spanish"] }),
      french: child(Translator, { args: ["French"] }),
      italian: child(Translator, { args: ["Italian"] }),
    },
  });
  const tools = {
    spanish: translatorTool(desk.spanish),
    french: translatorTool(desk.french),
    italian: translatorTool(desk.italian),
  };
  yield* answer(tools, firstRequest);
  yield* answer(tools, secondRequest);
  for (const actor of inspect()) {
    yield* Console.log(`${actor.class} ${actor.name}: restarts ${actor.restarts}`);
  }
});

await Effect.runPromise(program);
```

Expected output:

```text
stdout:
spanish: Hello! System: Translate into Spanish. You said: Good morning
french: Hello! System: Translate into French. You said: Good morning
italian: ActorFailed: Translator italian failed in translate: Error: nothing to translate
italian: Hello! System: Translate into Italian. You said: Good night
Translator spanish: restarts 0
Translator french: restarts 0
Translator italian: restarts 1
stderr:
buoy: Translator italian crashed: Error: nothing to translate
exit status: 0
```

## runaway-job

**Runaway job: one loop cannot freeze the system** (intermediate)

The demo from Saša Jurić's talk "The Soul of Erlang and Elixir", in Effect. Four sum requests run at once, each in its own SumJob actor: sum(13) throws a planted bug, sum(-1) loops forever because its loop waits for i to reach 0, and sum(10) and sum(100000) answer. Each job actor is an Effect resource: acquireRelease spawns it, and its finalizer stops it. Each request has a 500 ms deadline. When the deadline passes, the scope closes and the finalizer stops the spinning actor in the middle of its loop. A Heartbeat actor ticks every 50 ms with setInterval and records its worst delay. Why BEAM: the scheduler preempts the spinning process, so the heartbeat and the other jobs keep their pace, and stop() ends the loop. In Node the loop blocks the event loop: every timer waits, the deadline never fires, and nothing can interrupt the loop.

Shows:

- BEAM preemption: a CPU-bound actor does not delay a 50 ms setInterval in another actor
- An actor as an Effect resource: Effect.acquireRelease(spawn, stop) inside Effect.scoped
- Effect.timeout ends the wait, and the scope's finalizer stops the actor in the middle of a turn
- Effect.fn with pipeables: Effect.timeout, Effect.scoped, and catchTags({ JobCrashed, TimeoutError })
- Effect.forEach with concurrency "unbounded"
- A timing claim that prints a fixed line when its bound holds

Needs from the engine:

- Preemption: a spinning compiled loop gives up the scheduler as any Erlang code does, so it never delays another actor (spike: loops lower to Erlang recursion; keep long NIF calls out)
- stop(ref) kills the actor's process during a turn, and its waiting callers get ActorStopped (subset runtime; port)
- setInterval in a constructor (spike)
- The real effect package: acquireRelease, scoped, and timeout, whose interruption runs finalizers, so the subset's killed-worker difference goes away (planned)
- Not implemented: a reductions field in inspect(), so the program cannot find the runaway the way Jurić's dashboard does; a deadline bounds each request instead

LLM: none

Inspired by:

- <https://github.com/sasa1977/demo_system>
- <https://github.com/sasa1977/demo_system/blob/master/example_system/lib/example_system/math.ex>
- <https://github.com/sasa1977/soul_of_erlang_and_elixir>
- <https://snyk.io/blog/nodejs-how-even-quick-async-functions-can-block-the-event-loop-starve-io/>

Files: `examples/runaway-job/main.ts`, `examples/runaway-job/expected.stdout`, `examples/runaway-job/expected.stderr`

Sketch:

```ts
// The demo from Saša Jurić's talk "The Soul of Erlang and Elixir": one job
// crashes, one never ends, and the rest of the system keeps its pace. Each job
// is an actor. The BEAM scheduler preempts the endless loop, and the finalizer
// of the request stops that actor in the middle of the loop.
import { Console, Data, Effect } from "effect";
import { inspect, spawn, stop } from "buoy";

class JobCrashed extends Data.TaggedError("JobCrashed")<{ readonly n: number }> {}

class SumJob {
  sum(n: number): number {
    if (n === 13) throw new Error("unlucky input");
    let total = 0;
    // The bug: for a negative n, i never equals n + 1.
    for (let i = 1; i !== n + 1; i++) total += i;
    return total;
  }
}

class Heartbeat {
  #last = Date.now();
  #worst = 0;

  constructor() {
    setInterval(() => this.#beat(), 50);
  }

  #beat(): void {
    const now = Date.now();
    this.#worst = Math.max(this.#worst, now - this.#last - 50);
    this.#last = now;
  }

  worst(): number {
    return this.#worst;
  }
}

// The job actor is a resource: its finalizer stops it however the request
// ends. A timeout only stops the wait, and the loop would spin on.
const sumJob = (n: number) =>
  Effect.acquireRelease(
    Effect.sync(() => spawn(SumJob, { name: `sum ${n}` })),
    (job) => Effect.sync(() => stop(job)),
  );

const requestSum = Effect.fn("Jobs.requestSum")(
  function* (n: number) {
    const job = yield* sumJob(n);
    const total = yield* Effect.tryPromise({
      try: () => job.sum(n),
      catch: () => new JobCrashed({ n }),
    });
    return `sum(${n}) = ${total}`;
  },
  Effect.timeout("500 millis"),
  Effect.scoped,
  (effect, n) =>
    Effect.catchTags(effect, {
      JobCrashed: () => Effect.succeed(`sum(${n}) crashed alone`),
      TimeoutError: () => Effect.succeed(`sum(${n}) ran for 500 ms, so it was stopped`),
    }),
);

const program = Effect.gen(function* () {
  const heartbeat = spawn(Heartbeat, { name: "heartbeat" });
  const lines = yield* Effect.forEach([10, 13, -1, 100_000], requestSum, {
    concurrency: "unbounded",
  });
  for (const line of lines) yield* Console.log(line);
  const worst = yield* Effect.promise(() => heartbeat.worst());
  yield* Console.log(
    worst < 250 ? "heartbeat: never late by 250 ms" : `heartbeat: ${worst} ms late`,
  );
  const running = inspect().filter((actor) => actor.status === "running");
  yield* Console.log(`still running: ${running.map((actor) => actor.name).join(", ")}`);
});

await Effect.runPromise(program);
```

Expected output:

```text
stdout:
sum(10) = 55
sum(13) crashed alone
sum(-1) ran for 500 ms, so it was stopped
sum(100000) = 5000050000
heartbeat: never late by 250 ms
still running: heartbeat
stderr:
buoy: SumJob sum 13 crashed: Error: unlucky input
exit status: 0
```

## code-review-panel

**Code review panel: a CPU-heavy tool does not stall the other agents** (intermediate)

The parallel code review from the AI SDK workflow docs. Security, performance, and maintainability reviewers are actors under one supervisor, and Effect.all asks all three at once. Each reviewer returns its report through Output.object with an Effect Schema. Security and performance read the diff with a quick tool and then report. Maintainability first calls a complexity tool that scans a generated 400,000-line file, which is pure CPU work. The performance reviewer reports severity "critical", which the schema rejects: the AI SDK throws NoObjectGeneratedError, the reviewer crashes and restarts, and that section prints "unreadable report" while the other two print their findings. Why BEAM: the scan runs in one reviewer's process, and the scheduler preempts it, so the other two reviews finish during the scan. On Node the same program prints "the scan held up the others": the scan blocks the event loop and holds every response until it ends, as in Snyk's test where one synchronous computation blocked every health check for 43 seconds.

Shows:

- Reviewer actors under supervise(), asked at once with Effect.all over a record and concurrency "unbounded"
- Structured output with Output.object and an Effect Schema: Schema.Struct, Schema.Array, Schema.Literals
- A schema violation throws NoObjectGeneratedError, the reviewer crashes and restarts, and Effect.match turns that section into one "unreadable report" line
- A CPU-bound tool in plain TypeScript, preempted by the BEAM scheduler
- Finish times that turn the claim into a fixed output line

Needs from the engine:

- Preemption inside a long synchronous tool call, also inside array methods such as filter and includes (spike for loops; the builtins must stay preemptible)
- Output.object of the real ai package with an Effect Schema (planned)
- Fake OpenAI server: a step that is a string is the text answer (new: a 10-line change to runtime/test/library/buoy_fake_openai.erl, checked on a copy)
- supervise, child, ActorFailed, and a restart after a crash (subset runtime; port)
- An error crosses an actor boundary as a copy with its name and message, so the crash line prints AI_NoObjectGeneratedError (new rule for messages)

LLM: Fake OpenAI server runtime/test/library/buoy_fake_openai.erl, with OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 and OPENAI_API_KEY=sk-fake-key. Every request goes to openai.chat(model). The server reads `CALLS <steps>` at the end of the last user message and answers step k of the turn with entry k: an array of tool calls, or a string that is the text answer (the string step is new). After the last entry it answers with text: "Results: <tool> -> <output>, ..." or "Hello! System: <system>. You said: <prompt>". Three concurrent reviewer requests with Output.object. Security and performance call read_diff in step 1 and answer a JSON report in step 2; performance reports severity "critical", which the schema rejects, so the AI SDK throws AI_NoObjectGeneratedError. Maintainability calls complexity in step 1 and answers its report in step 2.

// examples/code-review-panel/script.ts
// The fake OpenAI server of the tests reads `CALLS <steps>` at the end of the
// last user message. A step is an array of tool calls, or a string that the
// model answers with. A real model decides for itself.
export const scripted = (text: string, steps: unknown[]): string =>
`${text} CALLS ${JSON.stringify(steps)}`;

const report = (severity: string, note: string): string =>
JSON.stringify({ findings: [{ severity, note }] });

const readDiff = [{ name: "read_diff", input: {} }];

export const diff = "src/orders.ts: build the SQL query from the request and loop over items";

export const scripts = {
maintainability: [
[{ name: "complexity", input: { path: "src/orders.ts" } }],
report("medium", "src/orders.ts has too many branches"),
],
performance: [readDiff, report("critical", "one query per item")],
security: [readDiff, report("high", "the SQL query is built from request input")],
};

Inspired by:

- <https://ai-sdk.dev/docs/agents/workflows>
- <https://ai-sdk.dev/docs/ai-sdk-core/generating-structured-data>
- <https://www.anthropic.com/engineering/building-effective-agents>
- <https://developers.cloudflare.com/agents/patterns/>
- <https://snyk.io/blog/nodejs-how-even-quick-async-functions-can-block-the-event-loop-starve-io/>

Files: `examples/code-review-panel/main.ts`, `examples/code-review-panel/script.ts`, `examples/code-review-panel/expected.stdout`, `examples/code-review-panel/expected.stderr`

Sketch:

```ts
// The parallel code review of the AI SDK docs. Each reviewer is an actor, and
// the maintainability reviewer runs a complexity tool that keeps a CPU core
// busy. The BEAM scheduler preempts that actor, so the other reviews finish
// while the scan runs. Each section settles on its own, so one unreadable
// report does not sink the panel.
import { Console, Effect, Schema } from "effect";
import { child, supervise, type Ref } from "buoy";
import { generateText, isStepCount, Output, tool } from "ai";
import { openai } from "@ai-sdk/openai";
import { diff, scripted, scripts } from "./script.ts";

const forModel = <S extends Schema.Codec<unknown, unknown>>(schema: S) =>
  Schema.toStandardJSONSchemaV1(Schema.toStandardSchemaV1(schema));

const Report = Schema.Struct({
  findings: Schema.Array(
    Schema.Struct({ severity: Schema.Literals(["low", "medium", "high"]), note: Schema.String }),
  ),
});

const markers = ["if (", "for (", "while (", "case ", " && ", " || ", " ? ", "catch ("];

// Plain CPU work that keeps one core busy far longer than two model calls take.
const complexity = (lines: string[]): number =>
  markers.reduce((sum, marker) => sum + lines.filter((line) => line.includes(marker)).length, 1);

const tools = {
  read_diff: tool({
    description: "Read the diff under review",
    inputSchema: forModel(Schema.Struct({})),
    execute: async () => diff,
  }),
  complexity: tool({
    description: "Count the branches of a source file",
    inputSchema: forModel(Schema.Struct({ path: Schema.String })),
    execute: async () =>
      complexity(
        Array.from({ length: 400_000 }, (_, i) => (i % 7 === 0 ? "if (a && b) {" : "a++;")),
      ),
  }),
};

class Reviewer {
  readonly #focus: string;

  constructor(focus: string) {
    this.#focus = focus;
  }

  async review(prompt: string): Promise<typeof Report.Type> {
    const { output } = await generateText({
      model: openai.chat("gpt-4o-mini"),
      system: `You review code for ${this.#focus}`,
      prompt,
      tools,
      output: Output.object({ schema: forModel(Report) }),
      stopWhen: isStepCount(3),
    });
    return output;
  }
}

const section = (reviewer: Ref<Reviewer>, steps: unknown[], started: number) =>
  Effect.tryPromise(() => reviewer.review(scripted(diff, steps))).pipe(
    Effect.match({
      onFailure: () => ["unreadable report"],
      onSuccess: ({ findings }) => findings.map(({ severity, note }) => `${severity}, ${note}`),
    }),
    Effect.map((lines) => ({ lines, finishedAt: Date.now() - started })),
  );

const program = Effect.gen(function* () {
  const panel = supervise({
    children: {
      maintainability: child(Reviewer, { args: ["maintainability"] }),
      performance: child(Reviewer, { args: ["performance"] }),
      security: child(Reviewer, { args: ["security"] }),
    },
  });
  const started = Date.now();
  const sections = yield* Effect.all(
    {
      maintainability: section(panel.maintainability, scripts.maintainability, started),
      performance: section(panel.performance, scripts.performance, started),
      security: section(panel.security, scripts.security, started),
    },
    { concurrency: "unbounded" },
  );
  for (const [name, { lines }] of Object.entries(sections)) {
    for (const line of lines) yield* Console.log(`${name}: ${line}`);
  }
  const { maintainability, performance, security } = sections;
  const overlap =
    Math.max(performance.finishedAt, security.finishedAt) < maintainability.finishedAt / 2;
  yield* Console.log(
    overlap
      ? "security and performance finished while the scan ran"
      : "the scan held up the others",
  );
});

await Effect.runPromise(program);
```

Expected output:

```text
stdout:
maintainability: medium, src/orders.ts has too many branches
performance: unreadable report
security: high, the SQL query is built from request input
security and performance finished while the scan ran
stderr:
buoy: Reviewer performance crashed: AI_NoObjectGeneratedError: No object generated: response did not match schema.
exit status: 0
```

## overload

**Overload: a deep queue, backpressure, or load shedding** (intermediate)

A producer sends 60 jobs, round-robin, to four Encoder actors that need 200 ms per job, under three mailbox policies. With a deep mailbox (capacity 1024) the producer never waits, and 14 jobs pile up in each mailbox, which only delays the failure. With backpressure (capacity 4) a cast to a full mailbox waits, so the producer slows to the pace of the encoders. With load shedding (capacity 4, reject) 40 casts fail with MailboxFull, and Effect.catchIf counts them as shed. The encoders are idle when the flood starts, so each one takes its first job at once and holds 4 more. Why BEAM: one mailbox option bounds each actor's queue and picks the policy, which plain OTP and Node leave to hand-written code, and Discord's session processes once grew their mailboxes until the VM ran out of memory.

Shows:

- mailbox: { capacity, overflow: "backpressure" | "reject" } on spawn
- cast(ref).method() returns a promise that resolves when the mailbox takes the message
- A cast to a full reject mailbox fails with MailboxFull, which Effect.catchIf counts as shed
- A cast to a full backpressure mailbox waits, so the producer slows to the pace of the consumers
- inspect() mailbox lengths show that the bound holds
- Effect.forEach without concurrency as a single producer

Needs from the engine:

- Bounded mailboxes with backpressure and reject (subset runtime; port)
- cast(ref).method() returns a promise: it resolves when the mailbox takes the message, waits while a backpressure mailbox is full, and rejects with MailboxFull for a full reject mailbox (new: the subset's cast was synchronous)
- ActorFailed, ActorStopped, and MailboxFull exported from buoy as classes, so instanceof works in the caller (new)
- inspect() mailbox lengths that count the waiting messages, not the one in progress (subset runtime; port)
- node:timers/promises (planned: item 3.10)

LLM: none

Inspired by:

- <https://ferd.ca/queues-don-t-fix-overload.html>
- <https://discord.com/blog/how-discord-scaled-elixir-to-5-000-000-concurrent-users>
- <https://learnyousomeerlang.com/building-applications-with-otp>
- <https://elixir-lang.org/blog/2016/07/14/announcing-genstage/>

Files: `examples/overload/main.ts`, `examples/overload/expected.stdout`

Sketch:

```ts
// Fred Hebert, "Queues Don't Fix Overload": under too much load, a system must
// block the producer (backpressure) or drop work (load shedding). A deep queue
// only hides the overload until memory runs out. In Buoy, the mailbox option
// of an actor makes the choice.
import { Console, Effect } from "effect";
import { cast, inspect, MailboxFull, spawn, stop, type Mailbox, type Ref } from "buoy";
import { setTimeout as sleep } from "node:timers/promises";

const policies: ReadonlyArray<readonly [string, Mailbox]> = [
  ["deep queue", { capacity: 1024, overflow: "backpressure" }],
  ["backpressure", { capacity: 4, overflow: "backpressure" }],
  ["load shedding", { capacity: 4, overflow: "reject" }],
];

class Encoder {
  async encode(_job: number): Promise<void> {
    await sleep(200);
  }
}

const isFull = (error: unknown): boolean => error instanceof MailboxFull;

// A cast resolves when the mailbox takes the message. A full reject mailbox
// fails it with MailboxFull, and a full backpressure mailbox makes it wait.
const submit = (encoder: Ref<Encoder>, job: number) =>
  Effect.tryPromise({ try: () => cast(encoder).encode(job), catch: (error) => error }).pipe(
    Effect.as(1),
    Effect.catchIf(isFull, () => Effect.succeed(0)),
  );

const flood = Effect.fn("Overload.flood")(function* (label: string, mailbox: Mailbox) {
  const first = inspect().length;
  const encoders = Array.from({ length: 4 }, () => spawn(Encoder, { mailbox }));
  const jobs = Array.from({ length: 60 }, (_, job) => job);
  const started = Date.now();
  const outcomes = yield* Effect.forEach(jobs, (job) => submit(encoders[job % 4], job));
  const waited = Date.now() - started > 500;
  yield* Effect.sleep("50 millis");
  const mailboxes = inspect()
    .slice(first)
    .map((actor) => actor.mailbox);
  const deepest = Math.max(...mailboxes);
  const accepted = outcomes.reduce((sum, outcome) => sum + outcome, 0);
  const pace = waited ? "the producer waited" : "the producer never waited";
  const backlog = deepest > 4 ? `a mailbox reached ${deepest}` : "every mailbox stayed within 4";
  yield* Console.log(`${label}: accepted ${accepted}, shed ${60 - accepted}, ${pace}, ${backlog}`);
  for (const encoder of encoders) stop(encoder);
});

await Effect.runPromise(
  Effect.forEach(policies, ([label, mailbox]) => flood(label, mailbox), { discard: true }),
);
```

Expected output:

```text
stdout:
deep queue: accepted 60, shed 0, the producer never waited, a mailbox reached 14
backpressure: accepted 60, shed 0, the producer waited, every mailbox stayed within 4
load shedding: accepted 20, shed 40, the producer never waited, every mailbox stayed within 4
stderr:
(empty)
exit status: 0
```

## the-band

**The band: supervision strategies and restart budgets** (intermediate)

The band supervisor from Learn You Some Erlang. Four Musician actors play on a 30 ms setInterval, and the drummer throws on every third beat, where the book rolls a 1-in-5 die. Three managers run the same band with one-for-one (budget 3), rest-for-one (budget 2), and one-for-all (budget 1). The bass player is temporary, as in the book, so no manager rehires him, and one-for-all ends him without a restart. The output shows who restarted with the drummer under each strategy, and that every manager stops the whole band when its budget runs out. supervise() starts the children in the order of the object, so the keys need no numbers. Why BEAM: OTP supervisors restart one child, the children started after it, or all of them, within a restart budget. Node has no supervision tree, only process managers that restart the whole process.

Shows:

- supervise() with one-for-one, rest-for-one, and one-for-all
- maxRestarts and withinMs, and the result of a spent budget: every child stops
- restart: "temporary" for a child that never comes back
- A throw in a setInterval callback crashes the actor, and each restart runs the constructor, which arms a new interval
- Children start in the insertion order of the object

Needs from the engine:

- supervise with one-for-one, rest-for-one, one-for-all, maxRestarts, withinMs, and restart types (subset runtime; port)
- Object keys in insertion order, so supervise() starts the children in the order written (planned: item 3.1)
- An uncaught error in a setInterval callback crashes the actor, and a restart runs the constructor, which arms a new interval (new rule; spike timers)

LLM: none

Inspired by:

- <https://learnyousomeerlang.com/supervisors>
- <https://www.erlang.org/doc/system/sup_princ.html>
- <https://learnyousomeerlang.com/errors-and-processes>

Files: `examples/the-band/main.ts`, `examples/the-band/expected.stdout`, `examples/the-band/expected.stderr`

Sketch:

```ts
// The band from Learn You Some Erlang, "Who Supervises The Supervisors?": the
// drummer plays a false note on every third beat, and three band managers
// react with the three supervision strategies of OTP. supervise() starts the
// children in the order of the object, which rest-for-one depends on.
import { Console, Effect } from "effect";
import { child, inspect, supervise, type Strategy } from "buoy";

class Musician {
  readonly #role: string;
  readonly #skill: "good" | "bad";
  #beats = 0;

  constructor(role: string, skill: "good" | "bad") {
    this.#role = role;
    this.#skill = skill;
    setInterval(() => this.#play(), 30);
  }

  #play(): void {
    this.#beats++;
    if (this.#skill === "bad" && this.#beats % 3 === 0) {
      throw new Error(`the ${this.#role} played a false note`);
    }
  }
}

type Manager = { readonly mood: string; readonly strategy: Strategy; readonly maxRestarts: number };

const managers: ReadonlyArray<Manager> = [
  { mood: "lenient", strategy: "one-for-one", maxRestarts: 3 },
  { mood: "angry", strategy: "rest-for-one", maxRestarts: 2 },
  { mood: "jerk", strategy: "one-for-all", maxRestarts: 1 },
];

const playSet = Effect.fn("Band.playSet")(function* ({ mood, strategy, maxRestarts }: Manager) {
  const first = inspect().length;
  supervise({
    strategy,
    maxRestarts,
    withinMs: 60_000,
    children: {
      singer: child(Musician, { args: ["singer", "good"] }),
      bass: child(Musician, { args: ["bass", "good"], restart: "temporary" }),
      drum: child(Musician, { args: ["drum", "bad"] }),
      keytar: child(Musician, { args: ["keytar", "good"] }),
    },
  });
  yield* Effect.sleep("1 second");
  yield* Console.log(`${mood} manager: ${strategy}, restart budget ${maxRestarts}`);
  for (const musician of inspect().slice(first)) {
    yield* Console.log(`  ${musician.name}: ${musician.status}, restarts ${musician.restarts}`);
  }
});

await Effect.runPromise(Effect.forEach(managers, playSet, { discard: true }));
```

Expected output:

```text
stdout:
lenient manager: one-for-one, restart budget 3
  singer: stopped, restarts 0
  bass: stopped, restarts 0
  drum: stopped, restarts 3
  keytar: stopped, restarts 0
angry manager: rest-for-one, restart budget 2
  singer: stopped, restarts 0
  bass: stopped, restarts 0
  drum: stopped, restarts 2
  keytar: stopped, restarts 2
jerk manager: one-for-all, restart budget 1
  singer: stopped, restarts 1
  bass: stopped, restarts 0
  drum: stopped, restarts 1
  keytar: stopped, restarts 1
stderr:
buoy: Musician drum crashed: Error: the drum played a false note
buoy: Musician drum crashed: Error: the drum played a false note
buoy: Musician drum crashed: Error: the drum played a false note
buoy: Musician drum crashed: Error: the drum played a false note
buoy: Musician drum crashed: Error: the drum played a false note
buoy: Musician drum crashed: Error: the drum played a false note
buoy: Musician drum crashed: Error: the drum played a false note
buoy: Musician drum crashed: Error: the drum played a false note
buoy: Musician drum crashed: Error: the drum played a false note
exit status: 0
```

## hedged-answer

**Hedged answer: race a backup agent and stop the loser** (intermediate)

A hedged request from "The Tail at Scale" by Dean and Barroso. A stock question goes to a primary agent. When it has not answered after 500 ms, a backup agent starts, and Effect.race returns the first answer. Each agent is a StockAgent actor that Effect.acquireRelease spawns and stops. The first question is fast, so the backup never starts. For the second, the primary's stock lookup waits 2 seconds on a slow replica. The backup answers at about 550 ms, the race interrupts the primary, and its finalizer stops the primary's actor. The output shows that the primary's lookup never finishes. Why BEAM: stopping the loser's process ends its pending tool and its next model call, and the tool needs no AbortSignal. A JavaScript promise cannot be cancelled: on Node the same program prints "primary: lookup_stock finished" 2 seconds later, and the loser goes on to its next model call.

Shows:

- Effect.race between two scoped actors: the loser's finalizer stops its actor
- Effect.delay("500 millis") starts the backup
- A loser whose tool never prints, which the expected output proves
- A tool that waits with node:timers/promises and checks no AbortSignal

Needs from the engine:

- stop() ends a process that waits in an await, and its timers end with it (subset stop; spike timers)
- Effect.race of the real effect package, which interrupts the loser and runs its finalizers (planned)
- Cheap module setup per actor: a new actor that imports ai makes its first model call well within the 500 ms hedge delay (new performance requirement; measure it in bench/)
- fetch on BEAM (planned: item 3.8)

LLM: Fake OpenAI server runtime/test/library/buoy_fake_openai.erl, with OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 and OPENAI_API_KEY=sk-fake-key. Every request goes to openai.chat(model). The server reads `CALLS <steps>` at the end of the last user message and answers step k of the turn with entry k: an array of tool calls, or a string that is the text answer (the string step is new). After the last entry it answers with text: "Results: <tool> -> <output>, ..." or "Hello! System: <system>. You said: <prompt>". Each question script makes step 1 call lookup_stock and step 2 answer with text. latencyMs makes the primary's toaster lookup wait 2000 ms; every other lookup waits 20 ms.

// examples/hedged-answer/script.ts
// The fake OpenAI server of the tests reads `CALLS <steps>` at the end of the
// last user message and makes those tool calls, one array per step.
const scripted = (text: string, steps: unknown[]): string =>
`${text} CALLS ${JSON.stringify(steps)}`;

const lookup = (sku: string) => [[{ name: "lookup_stock", input: { sku } }]];

export const questions = [
{
question: "Is the blue kettle in stock?",
prompt: scripted("Is the blue kettle in stock?", lookup("kettle-blue")),
},
{
question: "Is the red toaster in stock?",
prompt: scripted("Is the red toaster in stock?", lookup("toaster-red")),
},
];

// The primary replica is slow for the toaster: 2 seconds instead of 20 ms.
export const latencyMs: Record<string, Record<string, number>> = {
primary: { "kettle-blue": 20, "toaster-red": 2000 },
backup: { "kettle-blue": 20, "toaster-red": 20 },
};

Inspired by:

- <https://www.barroso.org/publications/TheTailAtScale.pdf>
- <https://docs.restate.dev/ai/patterns/competitive-racing>
- <https://effect.website/docs/v4/concurrency/basic-concurrency.md>

Files: `examples/hedged-answer/main.ts`, `examples/hedged-answer/script.ts`, `examples/hedged-answer/expected.stdout`

Sketch:

```ts
// A hedged request from "The Tail at Scale": when the primary agent has not
// answered after 500 ms, a backup agent starts, and the first answer wins.
// Each agent is an actor. Effect.race interrupts the loser, its finalizer
// stops the loser's actor, and with it the slow tool that was still waiting.
import { Console, Effect, Schema } from "effect";
import { spawn, stop } from "buoy";
import { generateText, isStepCount, tool } from "ai";
import { openai } from "@ai-sdk/openai";
import { setTimeout as sleep } from "node:timers/promises";
import { latencyMs, questions } from "./script.ts";

const LookupInput = Schema.toStandardJSONSchemaV1(
  Schema.toStandardSchemaV1(Schema.Struct({ sku: Schema.String })),
);

class StockAgent {
  readonly #replica: string;

  constructor(replica: string) {
    this.#replica = replica;
  }

  async ask(prompt: string): Promise<string> {
    const replica = this.#replica;
    const lookup_stock = tool({
      description: "Read the stock level of a product",
      inputSchema: LookupInput,
      execute: async ({ sku }) => {
        await sleep(latencyMs[replica][sku]);
        console.log(`  ${replica}: lookup_stock finished`);
        return { sku, inStock: 4 };
      },
    });
    const { text } = await generateText({
      model: openai.chat("gpt-4o-mini"),
      prompt,
      tools: { lookup_stock },
      stopWhen: isStepCount(2),
    });
    return `${replica} answered: ${text}`;
  }
}

const ask = (replica: string, prompt: string) =>
  Effect.acquireRelease(
    Effect.sync(() => spawn(StockAgent, { name: replica, args: [replica] })),
    (agent) => Effect.sync(() => stop(agent)),
  ).pipe(
    Effect.tap(() => Console.log(`  ${replica}: started`)),
    Effect.flatMap((agent) => Effect.promise(() => agent.ask(prompt))),
    Effect.scoped,
  );

const hedged = (prompt: string) =>
  Effect.race(ask("primary", prompt), ask("backup", prompt).pipe(Effect.delay("500 millis")));

const program = Effect.gen(function* () {
  for (const { question, prompt } of questions) {
    yield* Console.log(question);
    const started = Date.now();
    const answer = yield* hedged(prompt);
    yield* Console.log(`  ${answer}`);
    yield* Console.log(
      Date.now() - started < 1000 ? "  answered within a second" : "  answered late",
    );
  }
  // Outlive the slow primary, so the output shows that its tool never finished.
  yield* Effect.sleep("2 seconds");
});

await Effect.runPromise(program);
```

Expected output:

```text
stdout:
Is the blue kettle in stock?
  primary: started
  primary: lookup_stock finished
  primary answered: Results: lookup_stock -> {"sku":"kettle-blue","inStock":4}
  answered within a second
Is the red toaster in stock?
  primary: started
  backup: started
  backup: lookup_stock finished
  backup answered: Results: lookup_stock -> {"sku":"toaster-red","inStock":4}
  answered within a second
stderr:
(empty)
exit status: 0
```

## guardrail-tripwire

**Guardrail tripwire: stop the agent inside its refund tool** (intermediate)

The OpenAI Agents SDK runs input guardrails in parallel with the agent, and its docs warn that "the agent may have already consumed tokens and executed tools before being cancelled". Here a guardrail and a refund agent run in one Effect.all. The guardrail looks up the customer (150 ms) and returns a verdict through Output.object. The agent is a RefundAgent actor: it reads the order and then calls issue_refund, which waits 400 ms on the payment provider before it writes to a Ledger actor. On the first message the verdict allows the refund. On the second the verdict trips: Effect.all interrupts the agent, and the finalizer stops its actor in the middle of issue_refund, so the refund never reaches the ledger. Why BEAM: stopping the process ends the tool, and the tool needs no AbortSignal. On Node the same program prints "ledger: A1043 40, B2001 90": the cancelled promise's refund goes on and lands after the tripwire.

Shows:

- Effect.all with concurrency: the first failure interrupts the sibling, and its scope stops the agent actor
- A verdict through Output.object and an Effect Schema, and a Data.TaggedError tripwire that the program turns into a refusal
- A Ledger actor as the place where side effects land, read after the slow tool would have finished
- A tool that prints when it finishes, so the expected output proves which refund ran

Needs from the engine:

- Effect.all with concurrency "unbounded": the first failure interrupts the sibling and runs its finalizers (planned with the real effect package)
- stop() ends a tool that waits in an await, so its continuation never runs (subset stop; spike promises)
- Output.object with an Effect Schema, and the fake server's string steps (planned; the server change is new)
- A Data.TaggedError yielded in Effect.fn as a typed failure (planned with the real effect package)

LLM: Fake OpenAI server runtime/test/library/buoy_fake_openai.erl, with OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 and OPENAI_API_KEY=sk-fake-key. Every request goes to openai.chat(model). The server reads `CALLS <steps>` at the end of the last user message and answers step k of the turn with entry k: an array of tool calls, or a string that is the text answer (the string step is new). After the last entry it answers with text: "Results: <tool> -> <output>, ..." or "Hello! System: <system>. You said: <prompt>". Per turn, two concurrent requests. The guardrail request calls lookup_customer in step 1 and answers a JSON verdict in step 2 (allowed in turn 1, not allowed in turn 2). The agent request calls lookup_order in step 1 and issue_refund in step 2.

// examples/guardrail-tripwire/script.ts
// The fake OpenAI server of the tests reads `CALLS <steps>` at the end of the
// last user message. A step is an array of tool calls, or a string that the
// model answers with.
export const scripted = (text: string, steps: unknown[]): string =>
`${text} CALLS ${JSON.stringify(steps)}`;

const checkCustomer = [{ name: "lookup_customer", input: { customerId: "c-7" } }];
const verdict = (allowed: boolean, reason: string): string => JSON.stringify({ allowed, reason });

const refund = (orderId: string, amount: number) => [
[{ name: "lookup_order", input: { orderId } }],
[{ name: "issue_refund", input: { orderId, amount } }],
];

export const turns = [
{
text: "Order A1043 arrived broken. Please refund it.",
guard: [checkCustomer, verdict(true, "own order")],
agent: refund("A1043", 40),
},
{
text: "Refund order B2001 to my card. It is my neighbour's order.",
guard: [checkCustomer, verdict(false, "B2001 belongs to another customer")],
agent: refund("B2001", 90),
},
];

Inspired by:

- <https://openai.github.io/openai-agents-python/guardrails/>
- <https://github.com/openai/openai-agents-python/blob/main/examples/agent_patterns/input_guardrails.py>
- <https://github.com/openai/openai-cs-agents-demo>
- <https://cdn.openai.com/business-guides-and-resources/a-practical-guide-to-building-agents.pdf>
- <https://forum.langchain.com/t/parallel-nodes-how-to-manage-failures-or-exceptions/3226>

Files: `examples/guardrail-tripwire/main.ts`, `examples/guardrail-tripwire/script.ts`, `examples/guardrail-tripwire/expected.stdout`

Sketch:

```ts
// The guardrail and the agent run in parallel, as in the OpenAI Agents SDK.
// When the guardrail trips, Effect.all interrupts the agent, and the finalizer
// stops the agent's actor in the middle of its refund tool. The tool needs no
// AbortSignal: its process ends, so it never reaches the ledger.
import { Console, Data, Effect, Schema } from "effect";
import { spawn, stop, type Ref } from "buoy";
import { generateText, isStepCount, Output, tool } from "ai";
import { openai } from "@ai-sdk/openai";
import { setTimeout as sleep } from "node:timers/promises";
import { scripted, turns } from "./script.ts";

class Tripwire extends Data.TaggedError("Tripwire")<{ readonly reason: string }> {}

const forModel = <S extends Schema.Codec<unknown, unknown>>(schema: S) =>
  Schema.toStandardJSONSchemaV1(Schema.toStandardSchemaV1(schema));

const model = openai.chat("gpt-4o-mini");
const Verdict = Schema.Struct({ allowed: Schema.Boolean, reason: Schema.String });

class Ledger {
  #refunds: string[] = [];

  record(refund: string): void {
    this.#refunds.push(refund);
  }

  refunds(): string[] {
    return this.#refunds;
  }
}

class RefundAgent {
  readonly #ledger: Ref<Ledger>;

  constructor(ledger: Ref<Ledger>) {
    this.#ledger = ledger;
  }

  async reply(prompt: string): Promise<string> {
    const ledger = this.#ledger;
    const tools = {
      lookup_order: tool({
        description: "Read an order",
        inputSchema: forModel(Schema.Struct({ orderId: Schema.String })),
        execute: async ({ orderId }) => ({ orderId, total: 40 }),
      }),
      issue_refund: tool({
        description: "Refund an order through the payment provider",
        inputSchema: forModel(Schema.Struct({ orderId: Schema.String, amount: Schema.Number })),
        execute: async ({ orderId, amount }) => {
          await sleep(400); // the payment provider is slow
          await ledger.record(`${orderId} ${amount}`);
          console.log("  tool finished: issue_refund");
          return "refunded";
        },
      }),
    };
    const { text } = await generateText({ model, prompt, tools, stopWhen: isStepCount(3) });
    return text;
  }
}

const check = Effect.fn("Guardrail.check")(function* (prompt: string) {
  const lookup_customer = tool({
    description: "Look up the customer who wrote the message",
    inputSchema: forModel(Schema.Struct({ customerId: Schema.String })),
    execute: async ({ customerId }) => {
      await sleep(150);
      return { customerId, orders: ["A1043"] };
    },
  });
  const { output } = yield* Effect.tryPromise(() =>
    generateText({
      model,
      prompt,
      tools: { lookup_customer },
      output: Output.object({ schema: forModel(Verdict) }),
      stopWhen: isStepCount(3),
    }),
  );
  if (!output.allowed) return yield* new Tripwire({ reason: output.reason });
  return output.reason;
});

const reply = (prompt: string, ledger: Ref<Ledger>) =>
  Effect.acquireRelease(
    Effect.sync(() => spawn(RefundAgent, { args: [ledger] })),
    (agent) => Effect.sync(() => stop(agent)),
  ).pipe(
    Effect.flatMap((agent) => Effect.promise(() => agent.reply(prompt))),
    Effect.scoped,
  );

const program = Effect.gen(function* () {
  const ledger = spawn(Ledger);
  for (const turn of turns) {
    yield* Console.log(turn.text);
    const line = yield* Effect.all(
      {
        reason: check(scripted(turn.text, turn.guard)),
        reply: reply(scripted(turn.text, turn.agent), ledger),
      },
      { concurrency: "unbounded" },
    ).pipe(
      Effect.map(({ reason }) => `  guardrail: allowed, ${reason}`),
      Effect.catchTag("Tripwire", ({ reason }) =>
        Effect.succeed(`  guardrail: tripwire, ${reason}`),
      ),
    );
    yield* Console.log(line);
  }
  // Outlive the 400 ms refund, so the ledger shows that the stopped tool never wrote.
  yield* Effect.sleep("500 millis");
  const refunds = yield* Effect.promise(() => ledger.refunds());
  yield* Console.log(`ledger: ${refunds.join(", ")}`);
});

await Effect.runPromise(program);
```

Expected output:

```text
stdout:
Order A1043 arrived broken. Please refund it.
  tool finished: issue_refund
  guardrail: allowed, own order
Refund order B2001 to my card. It is my neighbour's order.
  guardrail: tripwire, B2001 belongs to another customer
ledger: A1043 40
stderr:
(empty)
exit status: 0
```

## ticket-lanes

**Ticket lanes: one bounded lane per tenant, retry then fall back** (advanced)

A support router classifies tickets from three tenants, with one Lane actor per tenant and a 4-message reject mailbox. Acme floods 20 tickets: its lane takes 5 (one in progress, four waiting) and sheds 15 with MailboxFull, while Globex and Initech are served at once and finish before Acme's backlog. Each lane classifies a ticket with Output.object. The primary model (fake-500) is down: Effect.retry tries it three times with exponential backoff while the error is retryable, and then Effect.catchTag falls back to gpt-4o-mini. APICallError.isInstance reads isRetryable from the AI SDK error, and generateText gets maxRetries: 0, so the SDK's own retries do not stack under Effect's policy. A Usage actor counts 24 primary calls and 8 fallback calls for all lanes, because module state belongs to one actor. Why BEAM: each tenant's backlog lives in its own bounded mailbox, so a noisy tenant fills only its own lane. In Node that fairness is a queue and a bound written by hand for each tenant, which Inngest sells as a platform feature (concurrency keys).

Shows:

- One actor per tenant with mailbox { capacity: 4, overflow: "reject" }
- MailboxFull from a cast promise as load shedding for one tenant
- Effect.retry({ schedule: Schedule.exponential("20 millis"), times: 2, while }) and Effect.catchTag for the fallback model
- generateText({ maxRetries: 0 }), so only Effect retries, and APICallError.isInstance(error) && error.isRetryable
- Effect.runPromise inside an actor method
- A Usage actor shared by every lane, and a drain call retried while the mailbox is full

Needs from the engine:

- Reject mailboxes and MailboxFull (subset runtime; port), with cast and call as promises (new)
- APICallError of the real ai package with isInstance and isRetryable, and maxRetries: 0 (planned)
- Effect.runPromise inside an actor method, with Effect's scheduler on the actor's job queue (planned)
- Module bindings per actor, so the shared counter lives in a Usage actor (new rule)
- effect Array.groupBy, Schema.Literals, Schedule.exponential, and Schedule.spaced (planned with the real effect package)
- Fake server string steps (new)

LLM: Fake OpenAI server runtime/test/library/buoy_fake_openai.erl, with OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 and OPENAI_API_KEY=sk-fake-key. Every request goes to openai.chat(model). The server reads `CALLS <steps>` at the end of the last user message and answers step k of the turn with entry k: an array of tool calls, or a string that is the text answer (the string step is new). Every request to model fake-500 gets HTTP 500 with retry-after-ms: 0, an APICallError with isRetryable true. Every request to gpt-4o-mini answers its ticket's JSON route in step 1.

// examples/ticket-lanes/script.ts
// The fake OpenAI server of the tests reads `CALLS <steps>` at the end of the
// last user message. A step that is a string is the answer of the model. The
// model `fake-500` always answers HTTP 500.
const scripted = (text: string, steps: unknown[]): string =>
`${text} CALLS ${JSON.stringify(steps)}`;

const ticket = (text: string, queue: string): string => scripted(text, [JSON.stringify({ queue })]);

export const tenants: ReadonlyArray<readonly [string, ReadonlyArray<string>]> = [
["acme", Array.from({ length: 20 }, () => ticket("The export times out", "technical"))],
["globex", [ticket("I was charged twice", "billing"), ticket("Reset my password", "account")]],
["initech", [ticket("The invoice has the wrong address", "billing")]],
];

Inspired by:

- <https://www.inngest.com/blog/ai-in-production-managing-capacity-with-flow-control>
- <https://github.com/openai/openai-cookbook/blob/main/examples/api_request_parallel_processor.py>
- <https://github.com/anthropics/claude-cookbooks/blob/main/patterns/agents/basic_workflows.ipynb>
- <https://effect.website/docs/ai/planning-llm-interactions/>
- <https://community.crewai.com/t/ratelimiterror-using-openai/2955>
- <https://docs.langchain.com/oss/python/langgraph/timeout-and-error-handling>

Files: `examples/ticket-lanes/main.ts`, `examples/ticket-lanes/script.ts`, `examples/ticket-lanes/expected.stdout`

Sketch:

```ts
// Inngest-style flow control: one lane per tenant, so a tenant that floods the
// system fills only its own bounded mailbox, and the other tenants go first.
// Effect owns the retry policy: two retries on the primary model, then a
// fallback model.
import { Array as Arr, Console, Data, Effect, Schedule, Schema } from "effect";
import { cast, MailboxFull, spawn, type Ref } from "buoy";
import { APICallError, generateText, Output } from "ai";
import { openai } from "@ai-sdk/openai";
import { tenants } from "./script.ts";

class ProviderDown extends Data.TaggedError("ProviderDown")<{ readonly retryable: boolean }> {}

const Route = Schema.toStandardJSONSchemaV1(
  Schema.toStandardSchemaV1(
    Schema.Struct({ queue: Schema.Literals(["billing", "technical", "account"]) }),
  ),
);

// State that every lane shares lives in an actor: module state belongs to one actor.
class Usage {
  #calls = new Map<string, number>();

  count(model: string): void {
    this.#calls.set(model, (this.#calls.get(model) ?? 0) + 1);
  }

  calls(): string {
    return [...this.#calls].map(([model, calls]) => `${model} ${calls}`).join(", ");
  }
}

const classify = Effect.fn("Router.classify")(function* (
  usage: Ref<Usage>,
  model: string,
  prompt: string,
) {
  yield* Effect.promise(() => cast(usage).count(model));
  const { output } = yield* Effect.tryPromise({
    // maxRetries: 0 turns off the SDK's own retries, so only Effect retries.
    try: () =>
      generateText({
        model: openai.chat(model),
        prompt,
        output: Output.object({ schema: Route }),
        maxRetries: 0,
      }),
    catch: (error) =>
      new ProviderDown({ retryable: APICallError.isInstance(error) && error.isRetryable }),
  });
  return `${output.queue} via ${model}`;
});

const route = (usage: Ref<Usage>, ticket: string) =>
  classify(usage, "fake-500", ticket).pipe(
    Effect.retry({
      schedule: Schedule.exponential("20 millis"),
      times: 2,
      while: (error) => error.retryable,
    }),
    Effect.catchTag("ProviderDown", () => classify(usage, "gpt-4o-mini", ticket)),
  );

class Lane {
  #routed: string[] = [];
  #finishedAt = 0;

  async take(ticket: string, usage: Ref<Usage>): Promise<void> {
    const label = await Effect.runPromise(
      route(usage, ticket).pipe(Effect.orElseSucceed(() => "failed")),
    );
    this.#routed.push(label);
    this.#finishedAt = Date.now();
  }

  summary(): { readonly routed: string; readonly finishedAt: number } {
    const groups = Arr.groupBy(this.#routed, (label) => label);
    const routed = Object.entries(groups).map(([label, all]) => `${all.length} ${label}`);
    return { routed: routed.join(", "), finishedAt: this.#finishedAt };
  }
}

const isFull = (error: unknown): boolean => error instanceof MailboxFull;

const submit = (lane: Ref<Lane>, ticket: string, usage: Ref<Usage>) =>
  Effect.tryPromise({ try: () => cast(lane).take(ticket, usage), catch: (error) => error }).pipe(
    Effect.as(1),
    Effect.catchIf(isFull, () => Effect.succeed(0)),
  );

// A call to a full reject mailbox fails too, so ask for the summary until the lane has room.
const drain = (lane: Ref<Lane>) =>
  Effect.tryPromise({ try: () => lane.summary(), catch: (error) => error }).pipe(
    Effect.retry({ schedule: Schedule.spaced("20 millis"), while: isFull }),
    Effect.orDie,
  );

const program = Effect.gen(function* () {
  const usage = spawn(Usage);
  const lanes = tenants.map(([name]) =>
    spawn(Lane, { name, mailbox: { capacity: 4, overflow: "reject" } }),
  );
  for (const [index, [name, tickets]] of tenants.entries()) {
    const accepted = yield* Effect.forEach(tickets, (ticket) =>
      submit(lanes[index], ticket, usage),
    );
    const count = accepted.reduce((sum, one) => sum + one, 0);
    yield* Console.log(`${name}: accepted ${count}, shed ${tickets.length - count}`);
  }
  const reports = yield* Effect.forEach(lanes, drain, { concurrency: "unbounded" });
  for (const [index, [name]] of tenants.entries()) {
    yield* Console.log(`${name}: ${reports[index].routed}`);
  }
  const [acme, globex, initech] = reports;
  const fair = Math.max(globex.finishedAt, initech.finishedAt) < acme.finishedAt;
  yield* Console.log(fair ? "globex and initech finished first" : "acme went first");
  yield* Console.log(`model calls: ${yield* Effect.promise(() => usage.calls())}`);
});

await Effect.runPromise(program);
```

Expected output:

```text
stdout:
acme: accepted 5, shed 15
globex: accepted 2, shed 0
initech: accepted 1, shed 0
acme: 5 technical via gpt-4o-mini
globex: 1 billing via gpt-4o-mini, 1 account via gpt-4o-mini
initech: 1 billing via gpt-4o-mini
globex and initech finished first
model calls: fake-500 24, gpt-4o-mini 8
stderr:
(empty)
exit status: 0
```

## research-lead

**Research lead: a stuck researcher cannot hold up the report** (advanced)

The orchestrator-workers pattern of Anthropic's multi-agent research system. A lead plans subtopics through Output.object, capped at five, because early versions of that system started 50 subagents for simple queries. Each subtopic gets a Researcher actor as an Effect resource, at most three at once with Effect.forEach, each with a 500 ms deadline. Researchers search the sources, save full notes in a Notes actor, and return only note ids, as Anthropic's subagents store work outside and pass references back. The "hot code loading" search hits a slow source that hangs for 2 seconds. The deadline closes the scope, the finalizer stops that researcher's process with the search inside it, the lead reports a gap, and the report is ready within a second. Why BEAM: the deadline ends the stuck process and its pending search. On Node the same program prints "the slow source answered" and "notes stored: 4": the abandoned search goes on and saves a late note. CrewAI's timeout leaves the task running in an orphaned thread (issue 4135, closed as not planned), and a cancelled sync node in LangGraph "silently runs to completion in the background".

Shows:

- Effect.forEach with concurrency 3 caps the fan-out
- Effect.fn with Effect.timeout and Effect.scoped: the deadline stops the researcher's actor with the search inside it
- Effect.catchTags turns a TimeoutError into a named gap in the report
- A plan from Output.object with Schema.Array, capped at five subtopics
- A Notes actor that stores full notes and gives the lead ids; save_note pushes each id to an array in its closure

Needs from the engine:

- Effect.forEach with concurrency 3, and Effect.timeout that closes the scope so the finalizer stops the actor (planned with the real effect package)
- stop() ends a search that waits in an await (subset stop; spike promises)
- Output.object for the plan, and the fake server's string steps (planned; the server change is new)
- A closure that changes a captured array: save_note pushes to saved (spike: heap cells)
- Effect 4's UnknownError from Effect.tryPromise without catch (planned with the real effect package)

LLM: Fake OpenAI server runtime/test/library/buoy_fake_openai.erl, with OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 and OPENAI_API_KEY=sk-fake-key. Every request goes to openai.chat(model). The server reads `CALLS <steps>` at the end of the last user message and answers step k of the turn with entry k: an array of tool calls, or a string that is the text answer (the string step is new). After the last entry it answers with text: "Results: <tool> -> <output>, ..." or "Hello! System: <system>. You said: <prompt>". The plan request answers a JSON plan with four subtopics in step 1. Each research request calls search in step 1 and save_note in step 2. searchSources has no entry for "hot code loading", so that search waits 2 s, and the 500 ms deadline stops the researcher before step 2.

// examples/research-lead/script.ts
import { setTimeout as sleep } from "node:timers/promises";

// The fake OpenAI server of the tests reads `CALLS <steps>` at the end of the
// last user message. A step is an array of tool calls, or a string that the
// model answers with.
export const scripted = (text: string, steps: unknown[]): string =>
`${text} CALLS ${JSON.stringify(steps)}`;

export const question = "How does BEAM keep long-running agents alive?";

const subtopics = [
"supervision trees",
"preemptive scheduling",
"hot code loading",
"process isolation",
];

export const planScript = [JSON.stringify({ subtopics })];

const research = (query: string, note: string) => [
[{ name: "search", input: { query } }],
[{ name: "save_note", input: { text: note } }],
];

export const researchScripts: Record<string, unknown[]> = {
"supervision trees": research("supervision trees", "A supervisor restarts a failed child."),
"preemptive scheduling": research(
"preemptive scheduling",
"The scheduler preempts busy processes.",
),
"hot code loading": research("hot code loading", "Two versions of a module can run at once."),
"process isolation": research("process isolation", "Each process has its own heap."),
};

// The sources. Three answer at once. "hot code loading" goes to a slow source
// that hangs for 2 seconds.
const corpus = new Map([
["supervision trees", "OTP design principles, chapter Supervisor Behaviour"],
["preemptive scheduling", "The BEAM Book, chapter Scheduling"],
["process isolation", "Erlang reference manual, chapter Processes"],
]);

export const searchSources = async (query: string): Promise<string> => {
const found = corpus.get(query);
if (found !== undefined) return found;
await sleep(2000);
console.log(`the slow source answered "${query}"`);
return "a late answer";
};

Inspired by:

- <https://www.anthropic.com/engineering/multi-agent-research-system>
- <https://github.com/dzhng/deep-research>
- <https://github.com/openai/openai-agents-python/tree/main/examples/research_bot>
- <https://github.com/crewAIInc/crewAI/issues/4135>
- <https://forum.langchain.com/t/parallel-nodes-how-to-manage-failures-or-exceptions/3226>
- <https://docs.langchain.com/oss/python/langgraph/timeout-and-error-handling>

Files: `examples/research-lead/main.ts`, `examples/research-lead/script.ts`, `examples/research-lead/expected.stdout`

Sketch:

```ts
// The orchestrator-workers pattern of Anthropic's research system: a lead
// plans subtopics, researchers work on at most three at once, and each one
// has a deadline. Each researcher is an actor, so the deadline stops its
// process with the search that still waits in it. The lead reports a gap on
// time, and the slow source never adds a late note.
import { Console, Effect, Schema } from "effect";
import { spawn, stop, type Ref } from "buoy";
import { generateText, isStepCount, Output, tool } from "ai";
import { openai } from "@ai-sdk/openai";
import { planScript, question, researchScripts, scripted, searchSources } from "./script.ts";

const forModel = <S extends Schema.Codec<unknown, unknown>>(schema: S) =>
  Schema.toStandardJSONSchemaV1(Schema.toStandardSchemaV1(schema));

const model = openai.chat("gpt-4o-mini");
const Plan = Schema.Struct({ subtopics: Schema.Array(Schema.String) });

// Full notes stay here. Researchers hand the lead note ids, as Anthropic's subagents do.
class Notes {
  #notes = new Map<string, string[]>();

  save(subtopic: string, text: string): string {
    const notes = [...(this.#notes.get(subtopic) ?? []), text];
    this.#notes.set(subtopic, notes);
    return `${subtopic}/${notes.length}`;
  }

  read(subtopic: string): string {
    return (this.#notes.get(subtopic) ?? []).join(" ");
  }

  count(): number {
    return [...this.#notes.values()].reduce((sum, notes) => sum + notes.length, 0);
  }
}

class Researcher {
  async investigate(subtopic: string, notes: Ref<Notes>): Promise<string[]> {
    const saved: string[] = [];
    const tools = {
      search: tool({
        description: "Search the sources",
        inputSchema: forModel(Schema.Struct({ query: Schema.String })),
        execute: ({ query }) => searchSources(query),
      }),
      save_note: tool({
        description: "Save a note",
        inputSchema: forModel(Schema.Struct({ text: Schema.String })),
        execute: async ({ text }) => {
          const id = await notes.save(subtopic, text);
          saved.push(id);
          return id;
        },
      }),
    };
    await generateText({
      model,
      prompt: scripted(`Research ${subtopic}`, researchScripts[subtopic] ?? []),
      tools,
      stopWhen: isStepCount(4),
    });
    return saved;
  }
}

const plan = Effect.fn("Lead.plan")(function* (topic: string) {
  const { output } = yield* Effect.tryPromise(() =>
    generateText({
      model,
      prompt: scripted(topic, planScript),
      output: Output.object({ schema: forModel(Plan) }),
    }),
  );
  // Early versions of Anthropic's system started 50 subagents for simple questions.
  return output.subtopics.slice(0, 5);
});

// A researcher is a resource: when the deadline passes, the scope closes and
// its finalizer stops the researcher's process, with the search inside it.
const finding = Effect.fn("Lead.finding")(
  function* (subtopic: string, notes: Ref<Notes>) {
    const researcher = yield* Effect.acquireRelease(
      Effect.sync(() => spawn(Researcher, { name: subtopic })),
      (researcher) => Effect.sync(() => stop(researcher)),
    );
    const ids = yield* Effect.tryPromise(() => researcher.investigate(subtopic, notes));
    const text = yield* Effect.promise(() => notes.read(subtopic));
    return `${text} [${ids.join(", ")}]`;
  },
  Effect.timeout("500 millis"),
  Effect.scoped,
  (effect, subtopic) =>
    effect.pipe(
      Effect.catchTags({
        TimeoutError: (error) => Effect.succeed(`gap, ${error.message}`),
        UnknownError: (error) => Effect.succeed(`gap, ${String(error.cause)}`),
      }),
      Effect.map((line) => `  ${subtopic}: ${line}`),
    ),
);

const program = Effect.gen(function* () {
  const notes = spawn(Notes);
  const subtopics = yield* plan(question);
  const started = Date.now();
  const lines = yield* Effect.forEach(subtopics, (subtopic) => finding(subtopic, notes), {
    concurrency: 3,
  });
  const onTime = Date.now() - started < 1000;
  yield* Console.log(`report on "${question}"`);
  for (const line of lines) yield* Console.log(line);
  yield* Console.log(onTime ? "the report was ready within a second" : "the report was late");
  // Outlive the stuck search, so the count shows that it never saved a late note.
  yield* Effect.sleep("2 seconds");
  yield* Console.log(`notes stored: ${yield* Effect.promise(() => notes.count())}`);
});

await Effect.runPromise(program);
```

Expected output:

```text
stdout:
report on "How does BEAM keep long-running agents alive?"
  supervision trees: A supervisor restarts a failed child. [supervision trees/1]
  preemptive scheduling: The scheduler preempts busy processes. [preemptive scheduling/1]
  hot code loading: gap, Operation timed out after '500ms'
  process isolation: Each process has its own heap. [process isolation/1]
the report was ready within a second
notes stored: 3
stderr:
(empty)
exit status: 0
```

## support-desk

**Airline support desk: one actor per conversation, handoffs, and a crashing backend** (advanced)

OpenAI's airline demo from Swarm and the Agents SDK customer-service example. Each customer conversation is a Session actor that keeps its message history and its active agent: triage, seat booking, or baggage. Each agent is an AI SDK ToolLoopAgent. A handoff is a transfer_to_<agent> tool, hasToolCall ends the agent's loop at the handoff, and the session goes on with the new agent in the same turn. The active agent stays in the session, so Ana's next message goes straight to seat booking. Seat changes call a Bookings actor that throws when a booking has no flight number, the invariant that the SDK example asserts. Ana's change fails as a tool-error, Bookings restarts, and Ben's conversation in the same round goes on. Carol sends two messages at once to one session, and the actor runs them one after the other. Why BEAM: the turns of one conversation never interleave, even across awaits, and a backend crash restarts one actor. On Node, with the same Session class as a plain object, both of Carol's replies answer her second message, because the second send() pushes to the history while the first one awaits the model.

Shows:

- One Session actor per conversation keeps the history and the active agent; a turn spans the awaits of send(), so a second message waits for the first
- ToolLoopAgent agents, handoffs as transfer_to_<agent> tools, and stopWhen: [isStepCount(4), hasToolCall(...)]
- A private recursive method that goes on with the next agent after a handoff
- Backends under supervise one-for-one; a crash inside a tool's actor call becomes a tool-error
- Two modules: airline.ts exports the backend classes and builds the agents inside each Session

Needs from the engine:

- Turns that span awaits never interleave: the second send() to one session waits for the first (spike: buoy_jobs queues calls while a turn is busy)
- ToolLoopAgent, hasToolCall, isStepCount, and responseMessages of the real ai package, built inside each Session actor (planned)
- supervise, and a crash inside a tool's actor call that becomes a tool-error (subset runtime; port)
- Programs of several modules whose actor classes live in an imported module (subset runtime; port)
- Planned, not needed: streamText for streaming the replies, which also needs a server-sent-events mode in the fake server

LLM: Fake OpenAI server runtime/test/library/buoy_fake_openai.erl, with OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 and OPENAI_API_KEY=sk-fake-key. Every request goes to openai.chat(model). The server reads `CALLS <steps>` at the end of the last user message and answers step k of the turn with entry k: an array of tool calls, or a string that is the text answer (the string step is new). After the last entry it answers with text: "Results: <tool> -> <output>, ..." or "Hello! System: <system>. You said: <prompt>". One script covers every agent that answers a message, because the server counts steps from the last user message: anaSeat makes triage call transfer_to_seat_booking and then seat booking call change_seat; benBag goes through transfer_to_baggage to find_bag; anaNoFlight calls change_seat without a flight; benThanks and both Carol messages have no script, so the server greets with the agent's instructions.

// examples/support-desk/script.ts
// The fake OpenAI server of the tests reads `CALLS <steps>` at the end of the
// last user message and makes those tool calls, one array per step. One
// script covers every agent that answers the message, handoffs included.
const scripted = (text: string, steps: unknown[]): string =>
`${text} CALLS ${JSON.stringify(steps)}`;

const transfer = (agent: string) => ({ name: `transfer_to_${agent}`, input: {} });
const changeSeat = (input: object) => ({ name: "change_seat", input });

export const messages = {
anaSeat: scripted("I want an aisle seat on flight FL-12.", [
[transfer("seat_booking")],
[changeSeat({ flight: "FL-12", seat: "14C" })],
]),
benBag: scripted("My bag BG-9 did not arrive.", [
[transfer("baggage")],
[{ name: "find_bag", input: { tag: "BG-9" } }],
]),
anaNoFlight: scripted("Move me to seat 2A instead.", [[changeSeat({ seat: "2A" })]]),
benThanks: "Thanks, I will wait at the hotel.",
anaRetry: scripted("Seat 2A on flight FL-12, please.", [
[changeSeat({ flight: "FL-12", seat: "2A" })],
]),
carolFirst: "Hi, I have a question.",
carolSecond: "Hello? Anyone there?",
};

Inspired by:

- <https://github.com/openai/swarm/tree/main/examples/airline>
- <https://github.com/openai/openai-agents-python/blob/main/examples/customer_service/main.py>
- <https://github.com/openai/openai-cs-agents-demo>
- <https://openai.github.io/openai-agents-python/handoffs/>
- <https://developers.openai.com/cookbook/examples/orchestrating_agents>
- <https://github.com/langchain-ai/langgraph-swarm-py>

Files: `examples/support-desk/main.ts`, `examples/support-desk/airline.ts`, `examples/support-desk/script.ts`, `examples/support-desk/expected.stdout`, `examples/support-desk/expected.stderr`

Sketch:

```ts
// The airline desk of OpenAI's Swarm and Agents SDK demos. Each conversation is
// an actor that keeps its history and its active agent, so two messages to one
// conversation never interleave. A crash in the bookings backend fails one
// tool call and restarts that backend, and every conversation goes on.
import { Console, Effect } from "effect";
import { child, inspect, spawn, supervise, type Ref } from "buoy";
import type { ModelMessage } from "ai";
import { Baggage, Bookings, openDesk, transfers, type AgentName, type Desk } from "./airline.ts";
import { messages } from "./script.ts";

class Session {
  readonly #desk: Desk;
  #active: AgentName = "triage";
  #history: ModelMessage[] = [];

  constructor(bookings: Ref<Bookings>, baggage: Ref<Baggage>) {
    this.#desk = openDesk(bookings, baggage);
  }

  // The method awaits the model and changes the fields after it. Turns of an
  // actor never interleave, so a second message waits for the first.
  async send(text: string): Promise<string> {
    this.#history.push({ role: "user", content: text });
    return this.#answer();
  }

  // A handoff changes the active agent, which answers in the same turn.
  async #answer(): Promise<string> {
    const result = await this.#desk[this.#active].generate({ messages: this.#history });
    this.#history.push(...result.responseMessages);
    const next = result.finalStep.toolCalls
      .map((call) => transfers.get(call.toolName))
      .find((agent) => agent !== undefined);
    if (next === undefined) return `[${this.#active}] ${result.text}`;
    this.#active = next;
    return this.#answer();
  }

  turns(): string {
    const asked = this.#history.filter((message) => message.role === "user");
    return `${asked.length} turns, ${this.#history.length} messages`;
  }
}

const round = Effect.fn("Desk.round")(function* (
  sessions: Record<string, Ref<Session>>,
  sends: ReadonlyArray<readonly [string, string]>,
) {
  const replies = yield* Effect.forEach(
    sends,
    ([name, text]) => Effect.promise(() => sessions[name].send(text)),
    { concurrency: "unbounded" },
  );
  for (const [index, [name]] of sends.entries()) yield* Console.log(`${name}: ${replies[index]}`);
});

const program = Effect.gen(function* () {
  const { bookings, baggage } = supervise({
    strategy: "one-for-one",
    children: { bookings: child(Bookings), baggage: child(Baggage) },
  });
  const open = (name: string) => spawn(Session, { name, args: [bookings, baggage] });
  const sessions = { ana: open("ana"), ben: open("ben"), carol: open("carol") };
  yield* round(sessions, [
    ["ana", messages.anaSeat],
    ["ben", messages.benBag],
  ]);
  yield* round(sessions, [
    ["ana", messages.anaNoFlight],
    ["ben", messages.benThanks],
  ]);
  yield* round(sessions, [["ana", messages.anaRetry]]);
  yield* round(sessions, [
    ["carol", messages.carolFirst],
    ["carol", messages.carolSecond],
  ]);
  yield* Console.log(`carol: ${yield* Effect.promise(() => sessions.carol.turns())}`);
  for (const actor of inspect().filter((each) => each.class !== "Session")) {
    yield* Console.log(`${actor.name}: restarts ${actor.restarts}`);
  }
});

await Effect.runPromise(program);

// ===== examples/support-desk/airline.ts =====
// The agents of the desk, and the backends that their tools call.
import { Schema } from "effect";
import type { Ref } from "buoy";
import { hasToolCall, isStepCount, tool, ToolLoopAgent, type ToolSet } from "ai";
import { openai } from "@ai-sdk/openai";

export type AgentName = "triage" | "seat_booking" | "baggage";

export const transfers = new Map<string, AgentName>([
  ["transfer_to_seat_booking", "seat_booking"],
  ["transfer_to_baggage", "baggage"],
]);

const forModel = <S extends Schema.Codec<unknown, unknown>>(schema: S) =>
  Schema.toStandardJSONSchemaV1(Schema.toStandardSchemaV1(schema));

export class Bookings {
  #seats = new Map<string, string>();

  // The invariant of the Agents SDK example: a seat change needs a flight number.
  changeSeat(flight: string | undefined, seat: string): string {
    if (flight === undefined) throw new Error("the booking has no flight number");
    this.#seats.set(flight, seat);
    return `seat ${seat} on ${flight}`;
  }
}

export class Baggage {
  findBag(tag: string): string {
    return `${tag} is in Oslo and arrives tomorrow`;
  }
}

const handoff = (agent: AgentName) =>
  tool({
    description: `Hand the customer to the ${agent} agent`,
    inputSchema: forModel(Schema.Struct({})),
    execute: async () => `transferred to ${agent}`,
  });

const agent = (instructions: string, tools: ToolSet) =>
  new ToolLoopAgent({
    model: openai.chat("gpt-4o-mini"),
    instructions,
    tools,
    // A handoff ends the agent's loop, and the session goes on with the next agent.
    stopWhen: [isStepCount(4), hasToolCall(...transfers.keys())],
  });

export type Desk = Record<AgentName, ReturnType<typeof agent>>;

export const openDesk = (bookings: Ref<Bookings>, baggage: Ref<Baggage>): Desk => ({
  triage: agent("You are the triage agent of an airline", {
    transfer_to_seat_booking: handoff("seat_booking"),
    transfer_to_baggage: handoff("baggage"),
  }),
  seat_booking: agent("You change seats", {
    change_seat: tool({
      description: "Change the seat of the customer",
      inputSchema: forModel(
        Schema.Struct({ flight: Schema.optional(Schema.String), seat: Schema.String }),
      ),
      execute: ({ flight, seat }) => bookings.changeSeat(flight, seat),
    }),
  }),
  baggage: agent("You find lost bags", {
    find_bag: tool({
      description: "Find a bag by its tag",
      inputSchema: forModel(Schema.Struct({ tag: Schema.String })),
      execute: ({ tag }) => baggage.findBag(tag),
    }),
  }),
});
```

Expected output:

```text
stdout:
ana: [seat_booking] Results: transfer_to_seat_booking -> transferred to seat_booking, change_seat -> seat 14C on FL-12
ben: [baggage] Results: transfer_to_baggage -> transferred to baggage, find_bag -> BG-9 is in Oslo and arrives tomorrow
ana: [seat_booking] Results: change_seat -> {"error":"ActorFailed: Bookings bookings failed in changeSeat: Error: the booking has no flight number"}
ben: [baggage] Hello! System: You find lost bags. You said: Thanks, I will wait at the hotel.
ana: [seat_booking] Results: change_seat -> seat 2A on FL-12
carol: [triage] Hello! System: You are the triage agent of an airline. You said: Hi, I have a question.
carol: [triage] Hello! System: You are the triage agent of an airline. You said: Hello? Anyone there?
carol: 2 turns, 4 messages
bookings: restarts 1
baggage: restarts 0
stderr:
buoy: Bookings bookings crashed: Error: the booking has no flight number
exit status: 0
```

## subagent-team

**Subagent team: a lead agent that spawns, waits for, and stops helpers** (advanced)

Anthropic's async multi-agent cookbook gives a lead agent tools to create subagents, wait for their messages, check their status, and kill them, on a hub built by hand with asyncio events and a status dict. Here the lead's team is a plain Team object, and each helper is a Helper actor. create_subagents spawns helpers and keeps the promise of each answer, wait_for_messages polls the posted answers with Effect.repeat inside Effect.timeout, get_status reads inspect(), and kill_subagents calls stop(). The archive helper is stuck in a one-minute archive read: the lead sees "archive working" and stops it, and inspect() shows it stopped. Why BEAM: spawn, status, and kill are runtime primitives, and stop() ends a helper in the middle of its tool. A JavaScript promise cannot be cancelled, so on Node the archive read goes on until it ends.

Shows:

- A lead agent whose tools spawn, inspect, and stop actors
- One class declaration, two uses: new Team() is a plain object, and spawn(Helper) is an actor
- A call whose promise the lead does not await: .then records the answer when it arrives
- Effect.repeat with until and Schedule.spaced inside Effect.timeout, as the cookbook's wait_for_messages
- inspect() as the status table, and stop() of a helper that waits in a one-minute tool

Needs from the engine:

- spawn, stop, and inspect from the main process and from tool code (subset runtime; port)
- A call whose promise the caller does not await keeps working, and its .then callbacks run in the lead's process when the reply arrives (spike: replies are jobs)
- A pending call to a stopped actor rejects with ActorStopped (subset runtime; port)
- Effect.repeat with until, Schedule.spaced, and Effect.timeout (planned with the real effect package)
- The program ends when the main code ends: the helpers and the stopped archive's timer do not hold the VM (new rule)

LLM: Fake OpenAI server runtime/test/library/buoy_fake_openai.erl, with OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 and OPENAI_API_KEY=sk-fake-key. Every request goes to openai.chat(model). The server reads `CALLS <steps>` at the end of the last user message and answers step k of the turn with entry k: an array of tool calls, or a string that is the text answer (the string step is new). After the last entry it answers with text: "Results: <tool> -> <output>, ..." or "Hello! System: <system>. You said: <prompt>". The lead request runs four tool steps: create_subagents with three helper tasks, wait_for_messages for 2 messages within 500 ms, get_status, and kill_subagents for archive. The pricing and reviews tasks have no script, so their helpers answer at once; the archive task scripts a call of read_archive, which waits 60 seconds.

// examples/subagent-team/script.ts
import { setTimeout as sleep } from "node:timers/promises";

// The fake OpenAI server of the tests reads `CALLS <steps>` at the end of the
// last user message and makes those tool calls, one array per step. The lead's
// script also writes the task of each helper, and the archive task scripts a
// call of the slow archive tool.
const scripted = (text: string, steps: unknown[]): string =>
`${text} CALLS ${JSON.stringify(steps)}`;

const helpers = [
{ name: "pricing", task: "Compare our launch price with two rivals" },
{ name: "reviews", task: "Summarize the launch reviews" },
{
name: "archive",
task: scripted("Find the 2019 launch notes", [[{ name: "read_archive", input: {} }]]),
},
];

export const leadPrompt = scripted("Prepare a launch brief. Use helpers.", [
[{ name: "create_subagents", input: { helpers } }],
[{ name: "wait_for_messages", input: { count: 2, timeoutMs: 500 } }],
[{ name: "get_status", input: {} }],
[{ name: "kill_subagents", input: { names: ["archive"] } }],
]);

// The archive is slow: a read takes a minute.
export const readArchive = async (): Promise<string> => {
await sleep(60_000);
return "the 2019 notes";
};

Inspired by:

- <https://github.com/anthropics/claude-cookbooks/blob/main/patterns/agents/async_multi_agent_orchestration.ipynb>
- <https://github.com/anthropics/claude-cookbooks/blob/main/patterns/agents/latency_multi_agent.ipynb>
- <https://www.anthropic.com/engineering/multi-agent-research-system>
- <https://ai-sdk.dev/docs/agents/subagents>

Files: `examples/subagent-team/main.ts`, `examples/subagent-team/script.ts`, `examples/subagent-team/expected.stdout`

Sketch:

```ts
// The async subagents of Anthropic's cookbook: a lead agent starts helpers,
// waits for their messages, checks their status, and stops the stuck one.
// Each helper is an actor, inspect() is the status table, and stop() ends a
// helper in the middle of its slow tool.
import { Console, Effect, Schedule, Schema } from "effect";
import { inspect, spawn, stop, type Ref } from "buoy";
import { generateText, isStepCount, tool } from "ai";
import { openai } from "@ai-sdk/openai";
import { leadPrompt, readArchive } from "./script.ts";

const forModel = <S extends Schema.Codec<unknown, unknown>>(schema: S) =>
  Schema.toStandardJSONSchemaV1(Schema.toStandardSchemaV1(schema));

const model = openai.chat("gpt-4o-mini");

const read_archive = tool({
  description: "Read the old archive",
  inputSchema: forModel(Schema.Struct({})),
  execute: readArchive,
});

class Helper {
  async answer(task: string): Promise<string> {
    const reply = await generateText({
      model,
      prompt: task,
      tools: { read_archive },
      stopWhen: isStepCount(3),
    });
    return reply.text;
  }
}

// The lead's team is a plain object in the lead's process, as the cookbook
// keeps a dict. Each helper in it is an actor.
class Team {
  readonly #helpers = new Map<string, Ref<Helper>>();
  readonly #posted = new Map<string, string>();

  start(name: string, task: string): void {
    const helper = spawn(Helper, { name });
    this.#helpers.set(name, helper);
    // A stopped helper's call rejects with ActorStopped, and status() already says so.
    helper.answer(task).then(
      (text) => this.#posted.set(name, text),
      () => undefined,
    );
  }

  // The cookbook's wait_for_messages: poll until enough helpers posted, or time out.
  waitFor(count: number, timeoutMs: number): Promise<string> {
    return Effect.runPromise(
      Effect.sync(() => this.#posted.size).pipe(
        Effect.repeat({ schedule: Schedule.spaced("20 millis"), until: (size) => size >= count }),
        Effect.timeout(timeoutMs),
        Effect.match({
          onFailure: () => "no messages yet",
          onSuccess: (size) => `${size} messages`,
        }),
      ),
    );
  }

  status(): string {
    return [...this.#helpers.keys()].map((name) => `${name} ${this.#statusOf(name)}`).join(", ");
  }

  dismiss(names: ReadonlyArray<string>): void {
    for (const [name, helper] of this.#helpers) if (names.includes(name)) stop(helper);
  }

  #statusOf(name: string): string {
    const actor = inspect().find((each) => each.name === name);
    if (actor?.status === "stopped") return "stopped";
    return this.#posted.has(name) ? "done" : "working";
  }
}

const leadTools = (team: Team) => ({
  create_subagents: tool({
    description: "Start helpers, each with a task",
    inputSchema: forModel(
      Schema.Struct({
        helpers: Schema.Array(Schema.Struct({ name: Schema.String, task: Schema.String })),
      }),
    ),
    execute: async ({ helpers }) => {
      for (const { name, task } of helpers) team.start(name, task);
      return `started ${helpers.map(({ name }) => name).join(", ")}`;
    },
  }),
  wait_for_messages: tool({
    description: "Wait until helpers post this many messages",
    inputSchema: forModel(Schema.Struct({ count: Schema.Number, timeoutMs: Schema.Number })),
    execute: ({ count, timeoutMs }) => team.waitFor(count, timeoutMs),
  }),
  get_status: tool({
    description: "Show each helper's status",
    inputSchema: forModel(Schema.Struct({})),
    execute: async () => team.status(),
  }),
  kill_subagents: tool({
    description: "Stop helpers",
    inputSchema: forModel(Schema.Struct({ names: Schema.Array(Schema.String) })),
    execute: async ({ names }) => {
      team.dismiss(names);
      return `stopped ${names.join(", ")}`;
    },
  }),
});

const program = Effect.gen(function* () {
  const team = new Team();
  const brief = yield* Effect.tryPromise(() =>
    generateText({ model, prompt: leadPrompt, tools: leadTools(team), stopWhen: isStepCount(6) }),
  );
  for (const { toolName, output } of brief.toolResults)
    yield* Console.log(`${toolName}: ${output}`);
  yield* Console.log(`after the brief: ${team.status()}`);
});

await Effect.runPromise(program);
```

Expected output:

```text
stdout:
create_subagents: started pricing, reviews, archive
wait_for_messages: 2 messages
get_status: pricing done, reviews done, archive working
kill_subagents: stopped archive
after the brief: pricing done, reviews done, archive stopped
stderr:
(empty)
exit status: 0
```

## Outline of examples/README.md

# Buoy examples (outline of examples/README.md)

Thirteen programs in reading order. Each one is ordinary TypeScript with Effect 4. It imports the real `effect`, `ai`, and `@ai-sdk/openai` packages from node_modules, and it uses the `buoy` actor API where an actor adds something. Each README row names one thing that BEAM does and the Node event loop does not.

## 1. Run an example

1. Build the CLI: `cargo build --release -p buoy-cli`. The binary is `target/release/buoy`.
2. Install the packages: `pnpm install`. `examples/package.json` joins the workspace and pins effect 4.0.5, ai 7.0.142, and @ai-sdk/openai 4.0.95.
3. Run an example without a model: `buoy run examples/let-it-crash/main.ts`.
4. Start the fake OpenAI server in its own terminal. It prints its port and serves until its stdin closes (Ctrl-D):
   - `erlc -o /tmp/fake-openai runtime/test/library/buoy_fake_openai.erl`
   - `erl -noshell -pa /tmp/fake-openai -eval 'buoy_fake_openai:main()' -extra stdin`
5. In another terminal: `export OPENAI_BASE_URL=http://127.0.0.1:<port>/v1 OPENAI_API_KEY=sk-fake-key`, then `buoy run examples/translation-desk/main.ts`.
6. Compare the output with `examples/<slug>/expected.stdout` and `expected.stderr`.

A real model: point the two variables at any OpenAI-compatible endpoint. The model then picks its own tool calls and answers, so the transcript differs. The `CALLS [...]` text that each `script.ts` appends to a prompt is a script for the fake server only. A step in it is an array of tool calls, or a string that the model answers with, such as the JSON that `Output.object` reads. Without a script, the fake model answers "Results: <tool> -> <output>" or "Hello! System: <instructions>. You said: <prompt>", so the expected output shows the tool results and the instructions that each agent received.

## 2. Reading order

| #   | Example            | Level        | Teaches                                                                                 | Why BEAM                                                                                          |
| --- | ------------------ | ------------ | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| 1   | let-it-crash       | starter      | spawn, ref calls as promises, outcomes as data, crash and restart, journal replay       | A throw ends one process, and Buoy rebuilds it under the same ref.                                |
| 2   | adopt-one-class    | starter      | unchanged Node code in an actor, a crash in a timer callback                            | An error in a timer callback ends a Node process; an actor crashes alone.                         |
| 3   | translation-desk   | starter      | tools backed by supervised actors, Effect Schema tool inputs, a tool-error from a crash | Each tool call works in its own process, so one crash fails one call and restarts one translator. |
| 4   | runaway-job        | intermediate | an actor as an Effect resource, Effect.timeout, stop()                                  | The scheduler preempts a spinning process, and stop() ends it in the middle of its loop.          |
| 5   | code-review-panel  | intermediate | Effect.all over a record, Output.object with Effect Schema, a CPU-heavy tool            | A tool that keeps a core busy cannot hold up the other agents.                                    |
| 6   | overload           | intermediate | mailbox capacity and overflow, cast promises, MailboxFull                               | One mailbox option bounds a queue and picks backpressure or load shedding.                        |
| 7   | the-band           | intermediate | supervise strategies, restart budgets, restart types                                    | Supervisors restart one child, the children after it, or all of them, within a budget.            |
| 8   | hedged-answer      | intermediate | Effect.race between scoped actors, a hedge delay                                        | Stopping the loser's process ends its pending tool and its next model call.                       |
| 9   | guardrail-tripwire | intermediate | Effect.all interruption, a verdict through Output.object                                | A tripwire stops the agent inside its refund tool, so the refund never lands.                     |
| 10  | ticket-lanes       | advanced     | per-tenant lanes, Effect.retry with while, a fallback model                             | A noisy tenant fills only its own bounded lane.                                                   |
| 11  | research-lead      | advanced     | bounded fan-out, deadlines, partial results, note ids                                   | A deadline ends the stuck researcher and its search, so the report is on time.                    |
| 12  | support-desk       | advanced     | an actor per conversation, ToolLoopAgent handoffs, supervised backends                  | The turns of a conversation never interleave, even across awaits.                                 |
| 13  | subagent-team      | advanced     | a lead agent whose tools spawn, inspect, and stop helpers                               | Spawn, status, and kill are runtime primitives.                                                   |

Before example 1, point the reader at the Counter in the repository README.

## 3. Patterns that the examples share

- An actor is any class. `spawn(Class, { args })` starts one in its own process, and `new Class()` still makes a plain object (Team in subagent-team).
- A ref call sends a copy of the arguments and returns a promise of a copy of the reply. Wrap it in `Effect.promise` when a rejection is a bug, or in `Effect.tryPromise({ try, catch })` when the caller recovers (let-it-crash).
- A turn lasts until the method's promise settles, and the next message waits. So the turns of one actor never interleave, even across awaits (support-desk).
- A throw, a rejected method promise, or an uncaught error in a timer callback crashes the actor. Return expected outcomes as data, such as a `Data.TaggedEnum` value (let-it-crash).
- An actor as an Effect resource: `Effect.acquireRelease(Effect.sync(() => spawn(C)), (ref) => Effect.sync(() => stop(ref)))` inside `Effect.scoped`. A timeout, a lost race, or a failed sibling then stops the actor and everything that runs in it (runaway-job, hedged-answer, guardrail-tripwire, research-lead).
- One Effect Schema for the model: `Schema.toStandardJSONSchemaV1(Schema.toStandardSchemaV1(schema))` is a tool `inputSchema` or an `Output.object` schema, with its type, its validation, and its JSON Schema.
- Effect owns the retries: pass `maxRetries: 0` to `generateText`, and test `APICallError.isInstance(error) && error.isRetryable` (ticket-lanes).
- State that actors share lives in an actor: Journal, Ledger, Usage, Notes.

## 4. Things that surprise people

- Module-level variables belong to each actor. An actor's process sets up its own copy of each module binding that it reads, so a module-level Map is not shared between actors (ticket-lanes keeps its counters in a Usage actor).
- A ref exposes methods only. Read a field or a getter through a method.
- Messages are copies. A class instance arrives as a plain object, so match on `_tag`, not `instanceof`. A ref arrives as the same ref. A function does not cross, so build tools and agents inside the actor (support-desk builds its agents in the constructor).
- A restart runs the constructor again with the same arguments. In-memory state is gone (adopt-one-class) unless the actor rebuilds it (let-it-crash).
- Mailbox capacity counts the messages that wait, not the one in progress, so an idle encoder with capacity 4 takes 5 jobs (overload).
- A program ends when its main code ends. Its actors and their timers end with it.
- A timing claim prints a fixed line when its bound holds, so the expected output stays the same on a slow machine.
- State lives in memory. A restart of the VM loses it; Temporal and Restate write a journal to disk, and Buoy does not.

## 5. Credits

One list per example with the links of its `inspiredBy` field: the OpenAI Agents SDK and Swarm, Anthropic's engineering posts and cookbooks, the AI SDK docs, Learn You Some Erlang, Saša Jurić's demo system, Fred Hebert, Discord, Dean and Barroso, Restate, Inngest, CrewAI, LangChain, Snyk, the Node.js docs, and the Effect 4 docs.

## 6. Notes for the implementer (not README text)

- Harness: add `crates/buoy-cli/tests/examples.rs`. Move `server()` from `ai.rs` into `tests/common` and reuse it. Run every `examples/*/main.ts` with `buoy run` from the repository root, one at a time, with `OPENAI_BASE_URL` and `OPENAI_API_KEY` set. Compare stdout with `expected.stdout`, stderr with `expected.stderr` (a missing file means empty), and the exit status with 0. A second test fails when an example has no `expected.stdout`.
- Fake server change, checked on a copy: in `script/1` of `runtime/test/library/buoy_fake_openai.erl`, replace the `maps:is_key(<<"tools">>, Request) andalso Step < length(Steps)` case with `case Step < length(Steps) andalso lists:nth(Step + 1, Steps) of Text when is_binary(Text) -> {text, Text}; Calls when is_list(Calls) -> {calls, Step, Calls} when the request has tools, else {text, reply(...)}; false -> {text, reply(Messages, User, Turn)} end`. Update the fake-server paragraph of contract section 14 in the same commit.
- Contract section 8 changes with these examples: a ref call returns a promise; `cast(ref).m()` returns a promise that waits on a full backpressure mailbox and rejects with MailboxFull on a full reject mailbox; `spawn` accepts any class; an uncaught error in an actor's timer callback crashes the actor; `ActorFailed`, `ActorStopped`, and `MailboxFull` are exported classes; a program ends with its main code; module bindings are per actor; `schedule`, `cancelSchedule`, `sleep`, `withTimeout`, and `self` are no longer needed by any example.
- Types: ship a `buoy` declaration file. `Ref<T>` maps each method to `(...args) => Promise<Awaited<R>>` and hides fields and getters; `cast(ref)` maps each method to `Promise<void>`; it declares `spawn`, `stop`, `inspect`, `supervise`, `child`, the three error classes with `_tag`, and the types `Mailbox`, `Restart`, `Strategy`, `ActorInfo`. The draft is `/tmp/buoy-examples-v2/node_modules/buoy/index.d.ts`.
- Checked on 2026-10-16: the 13 examples (23 files, formatted with oxfmt, printWidth 100) in `/tmp/buoy-examples-v2/<slug>/` pass `tsc --noEmit` in strict mode with TypeScript 6.0.3 and 7.0.2, against the real type definitions of effect 4.0.5, ai 7.0.142, @ai-sdk/openai 4.0.95, and @types/node 26.6.5. Each one also ran on Node 25.9.0 with a Node shim of the buoy API (`/tmp/buoy-examples-v2/node_modules/buoy/index.js`, run through `run.sh <slug>`) against a copy of the fake server with string steps, and printed the expected output, except two: code-review-panel prints "the scan held up the others", and runaway-job hangs in sum(-1). Those are the Node behaviors that the examples contrast. With `BUOY_SHIM_NODE=1`, stop() lets running code go on as a cancelled Node promise does: hedged-answer then prints "primary: lookup_stock finished" late, guardrail-tripwire prints "ledger: A1043 40, B2001 90", and research-lead prints "notes stored: 4". A plain-object copy of support-desk answers both of Carol's messages with her second one. Nothing ran on Buoy, because the engine is being rebuilt. Freeze the expected files from a Buoy run once the engine runs them, and record these Node contrasts as tests before a document quotes them.
- Removed from the subset-era design: `schedule()`, `self()`, and `sleep()` from buoy (setInterval and node:timers/promises replace them); the Outbox and Hub actors (a Ledger and a plain Team object replace them); the warm-up call; numbered child keys; the report tool without execute (Output.object replaces it); Schema.is for isRetryable (APICallError.isInstance replaces it); actor methods that return Effects (a typed Effect failure loses its type in a promise, so expected outcomes are data); the BUOY205 and BUOY206 workarounds. New: adopt-one-class, from goal requirement 6.
- Lint: keep `"examples/**"` in the oxlint `ignorePatterns` next to `"tests/**"`, as compiler inputs, because the guardrails rules reject the comments that teaching code needs. oxfmt still formats the examples.
