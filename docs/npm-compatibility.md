# npm compatibility

This note explains how npm packages run inside Bouy actors. It lists the packages and the APIs that end-to-end tests prove, and it states the known limits.

## The compatibility path

- Bouy compiles only your own source files. The loader in `packages/bouy/src/loader/Loader.ts` sends a file to the Rust compiler when the path ends in `.ts`, `.mts`, or `.tsx`, is not a `.d.ts` file, is not under `node_modules`, and is not part of the Bouy runtime. `bouy run`, `node --import bouy/register`, and `bun --preload bouy/register` all use this loader.
- npm packages load unchanged through the module loader of Node or Bun. On Node, the loader hook passes every other file to Node's own loader. On Bun, the plugin returns every other TypeScript file with its contents unchanged, and Bun loads JavaScript files without the plugin. Nothing rewrites, wraps, or bundles package code.
- Values that cross an actor boundary must be Sendable. Sendable values are strings, numbers, booleans, bigints, `null`, `undefined`, `Date`, `Uint8Array`, actor refs, and arrays, `Map`s, `Set`s, and plain objects built from these. The runtime copies every argument list and every result that holds an object through an Effect Schema, and it passes primitives through unchanged (`copyArguments` and `copyValue` in `packages/bouy/src/runtime/Sendable.ts`). A primitive cannot change, so in both cases a sender cannot change data after it sends it. Any other value fails with `NotSendable`, and the error names the path of the value, for example `a function at [0][meta][render]`.
- Library objects stay inside the actor that created them. A zod schema and an AI SDK model are class instances, so they cannot cross. Create them inside the actor, or at module level, and send plain data in and out: the parsed record, the issue list, the generated text, or the tool result. `examples/zod-validation.ts` and `examples/research-team.ts` follow this rule.
- Module-level state in a package is shared by every actor in the thread. All actors run in one isolate with one module graph. If one actor changes state that a package keeps at module level, every other actor sees the change.

## Packages and APIs that the tests prove

Each test runs real processes. The hosts are Node v25.9.0 through `bouy run` and through `node --import bouy/register`, and Bun 1.3.11 through `bouy run` and through `bun --preload bouy/register`. The fake OpenAI server in `examples/fake-openai.ts` answers every model call on `127.0.0.1`, so the tests need no network and no API key.

| Package                  | Version | APIs and behavior                                                                                                                                                                                                                                              | Test                                         |
| ------------------------ | ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `zod`                    | 4.6.7   | `z.object`, `z.string().min`, `z.number().int().positive`, `z.array().default`; `parse` that succeeds; `parse` that throws `z.ZodError`, with `instanceof z.ZodError` and the issue list; `safeParse` that succeeds and that fails                             | `e2e/npm-equivalence.test.ts`                |
| `ai`                     | 7.0.142 | `generateText` with `text`, `finishReason`, `usage`, `warnings`, and the response `id`, `modelId`, and `timestamp`; `streamText` with `textStream`, `text`, `finishReason`, and `usage`; `tool` with `inputSchema` and `execute`; `isStepCount` for tool loops | `e2e/npm-equivalence.test.ts`                |
| `@ai-sdk/openai`         | 4.0.95  | `createOpenAI({ baseURL, apiKey }).chat("gpt-5")` against Chat Completions: JSON responses, server-sent event streams that end with `data: [DONE]`, and `tool_calls` with `finish_reason: "tool_calls"`, streamed and not streamed                             | `e2e/npm-equivalence.test.ts`                |
| `@ai-sdk/provider-utils` | 5.0.61  | Loaded by `ai` and `@ai-sdk/openai` for `tool` and for JSON and event-stream parsing                                                                                                                                                                           | `e2e/npm-equivalence.test.ts`                |
| `@ai-sdk/provider`       | 4.0.28  | Loaded by `ai` and `@ai-sdk/openai`                                                                                                                                                                                                                            | `e2e/npm-equivalence.test.ts`                |
| `zod`                    | 4.6.7   | `z.email`, `z.enum`, `z.number().int().min`, and `safeParse` inside an actor method, with the issue list returned as plain data                                                                                                                                | `e2e/examples.test.ts`, zod-validation cases |
| `ai`                     | 7.0.142 | A tool whose `execute` calls another actor inside `withSignal`; a failed tool call that reaches the model as a tool error; `streamText` relayed through an async generator method                                                                              | `e2e/examples.test.ts`, research-team cases  |
| `zod`                    | 4.6.7   | A `ZodObject` sent to an actor fails with `an instance of ZodObject at [0]`. A `ZodError` thrown inside an actor reaches the caller as `ActorFailed`, whose `cause` is named `ZodError` but is not an instance of `z.ZodError`.                                | `e2e/isolation.test.ts`                      |
| `@ai-sdk/openai`         | 4.0.95  | A chat model sent to an actor fails with `an instance of OpenAIChatLanguageModel at [0]`                                                                                                                                                                       | `e2e/isolation.test.ts`                      |
| `zod`                    | 4.6.7   | `z.config({ customError })` called in one actor changes the error messages that another actor produces                                                                                                                                                         | `e2e/isolation.test.ts`, shared-state cases  |

The equivalence test covers the first five rows. It works as follows:

1. `e2e/test/npm-scenario.ts` calls each of those APIs and returns one plain report.
2. `e2e/test/npm-plain.ts` runs the scenario as plain code under `node`, with no Bouy import, and prints the report as canonical JSON with sorted keys.
3. `e2e/test/npm-actors.ts` runs the same scenario in three actors at once on each Bouy host. It fails if the three reports differ, and it prints the report the same way.
4. The test asserts that each Bouy host prints the same bytes as plain Node.

The test also reads this note. It takes the Version column of every row whose Test column is `e2e/npm-equivalence.test.ts`, and it fails if an installed package has another version. Update this table when you upgrade one of those packages.

Run the tests from the repository root:

```sh
pnpm --filter @bouy/e2e test
```

## Known limits

- Package code has no preemption points. The compiler never sees files under `node_modules`, so a long synchronous call into a package blocks every other actor on the thread until it returns. The plain-node case in `e2e/fairness.test.ts` shows the same effect for an uncompiled loop.
- A library object cannot be an argument or a result. Keep it in the actor and send plain data. To stream from an actor, use an async generator method, as the `Writer` in `examples/research-team.ts` does with `yield* result.textStream`.
- Errors cross as copies. When an actor method throws, the caller receives `ActorFailed`, and its `cause` is a plain `Error` with the original name, message, and stack (`copyError` in `packages/bouy/src/runtime/Sendable.ts`). An `instanceof` check against the library error class fails on that copy. Return library failures as data, as `safeParse` does, when the caller must inspect them.
- Module-level state is shared, not isolated. A package-wide setting, cache, or connection pool that one actor changes changes for every actor on the thread.
- On Bun 1.3.11, a `queueMicrotask` callback that throws and a floating promise that rejects inside an actor escape fault attribution. Bun loses the `AsyncLocalStorage` store in the `uncaughtException` and `unhandledRejection` handlers. The runtime prints the error, sets exit code 1, and does not restart the actor. `e2e/faults.test.ts` asserts this behavior. On Node v25.9.0 the same faults restart the actor.
- A throw in an `EventEmitter` listener restarts the actor that called `emit()`, not the actor that registered the listener. A listener runs in the async context of `emit()`, and the runtime attributes a fault through that context. The actor that registered the listener keeps its state, and the listener stays subscribed. The case `restarts the actor whose EventEmitter listener throws, not the actor that emits` in `e2e/faults.test.ts` fails on all four hosts until the runtime attributes the fault to the listener's actor.
- `bouy run` gives the program the argument vector of the CLI. `process.argv[1]` is the path of `bouy/src/cli/main.ts`, and `process.argv.slice(2)` starts with `run` and the entry. A program that compares `import.meta.url` with `process.argv[1]` to detect its entry point skips its main code and exits 0. `bouy run` also rejects arguments after the entry. `import.meta.main` is `false`, because the CLI loads the entry with a dynamic `import()`. `node --import bouy/register` and `bun --preload bouy/register` give the program its own path and arguments, and `import.meta.main` is `true`. `e2e/argv.test.ts` fails on both `bouy run` hosts until the CLI passes the arguments through.
- The AI SDK gives a tool `execute` function an optional `abortSignal`, and `withSignal` needs a signal. Write `withSignal(abortSignal ?? signal(), ...)` so that the call falls back to the signal of the current turn.
- The fake server covers the part of Chat Completions that `@ai-sdk/openai` 4.0.95 parses for text, streamed text, and one tool call per model turn. The tests do not cover the Responses API, real network failures, retries, or TLS.
