# Examples

Each example runs on Node and on Bun. Run `pnpm install` at the repository root once, then run the commands below from this directory.

| File                | What it shows                                                                                                                                                                                                                                                                                                                                                               |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `hello.ts`          | `spawn`, calls, a crash that restarts the actor under `supervise`, and `inspect`.                                                                                                                                                                                                                                                                                           |
| `research-team.ts`  | Three `ResearchAgent` actors call `generateText` at the same time. A `WebSearch` actor is their AI SDK tool. The tool crashes on an unknown topic, its supervisor restarts it, and the researchers keep working. A `Writer` actor streams a summary from `streamText` through an async generator method, and the program prints how many chunks crossed the actor boundary. |
| `zod-validation.ts` | An actor validates records with a zod 4 schema and returns the parsed record or the issue list as plain data.                                                                                                                                                                                                                                                               |
| `fake-openai.ts`    | A local OpenAI Chat Completions server that `research-team.ts` and the end-to-end tests start. It is a module, not a program.                                                                                                                                                                                                                                               |

## Commands

Node, through the Bouy CLI:

```sh
./node_modules/.bin/bouy run hello.ts
./node_modules/.bin/bouy run research-team.ts
./node_modules/.bin/bouy run zod-validation.ts
```

Bun, through the Bouy CLI:

```sh
bun ../packages/bouy/dist/cli.mjs run hello.ts
bun ../packages/bouy/dist/cli.mjs run research-team.ts
bun ../packages/bouy/dist/cli.mjs run zod-validation.ts
```

Without the CLI, register the compiler as a loader hook. Replace `hello.ts` with any example:

```sh
node --import bouy/register hello.ts
bun --preload bouy/register hello.ts
```

`node hello.ts` also runs, but without the compiler. The program then has no preemption points, so a long loop in one actor blocks every other actor.

## Output of research-team.ts

```text
actor model (1 tool call): Answer about "actor model". The tool returned ["An actor owns its state.","Actors talk only through messages."]
supervision trees (1 tool call): Answer about "supervision trees". The tool returned ["A supervisor restarts a failed child with fresh state."]
green threads (1 tool call): Answer about "green threads". The tool returned {"error":"ActorFailed: search#2 failed in query: Error: the search index has no entry for \"green threads\""}
summary (12 chunks): Answer about "Summarize the research on actor model, supervision trees, green threads.".
The fake model served 7 requests, at most 3 at once.
ada: restarts 0
grace: restarts 0
linus: restarts 0
search: restarts 1
writer: restarts 0
```

`e2e/examples.test.ts` checks the output of every example on all four host commands.

## The fake OpenAI server

`FakeOpenAI.start({ latencyMs })` listens on a free port of `127.0.0.1` and resolves when the server is ready. Pass `fake.baseURL` to `createOpenAI({ baseURL, apiKey: "test" }).chat("gpt-5")`, and call `fake.stop()` when you are done.

The server implements `POST /v1/chat/completions` for `@ai-sdk/openai` 4.0.95:

- A request without tools gets the answer `Answer about "<last user message>".`
- A request with tools, whose last message comes from the user, gets one call to the first tool. Every required parameter of that tool gets the text of the last user message. The finish reason is `tool_calls`.
- A request whose last message is a tool result gets the answer text followed by `The tool returned <tool result>`.
- `stream: true` sends the same answer as server-sent events: one `data:` line per word of text, or one for the tool call, then a finish chunk, a usage chunk, and `data: [DONE]`.
- The server waits `latencyMs` milliseconds before each answer.
- The response id, the tool call id, and the `created` time do not depend on the clock, so two runs with the same prompts give the same output.
- `served` counts answered requests, and `peakConcurrency` records the most requests in flight at one time.
