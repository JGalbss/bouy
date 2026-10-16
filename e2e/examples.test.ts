import { describe, expect, it } from "vitest";
import { BOUY_HOSTS, EXAMPLES, launch, CHILD_TIMEOUT_MS, TEST_TIMEOUT_MS } from "./hosts.ts";

const options = { cwd: EXAMPLES, timeoutMs: CHILD_TIMEOUT_MS };

const HELLO = [
  "Hello, Ada! (1 greeted, checksum 499500)",
  "Hello, Grace! (2 greeted, checksum 499500)",
  "caught: greeter#3 failed in fail: Error: the greeter tripped",
  "Hello, Linus! (1 greeted, checksum 499500)",
  "Greeter: idle, restarts 0",
  "greeter: idle, restarts 1",
  "",
].join("\n");

const RESEARCH_TEAM = [
  'actor model (1 tool call): Answer about "actor model". The tool returned ["An actor owns its state.","Actors talk only through messages."]',
  'supervision trees (1 tool call): Answer about "supervision trees". The tool returned ["A supervisor restarts a failed child with fresh state."]',
  expect.stringMatching(
    /^green threads \(1 tool call\): Answer about "green threads"\. The tool returned \{"error":"ActorFailed: search#\d+ failed in query: Error: the search index has no entry for \\"green threads\\""\}$/u,
  ),
  'summary (12 chunks): Answer about "Summarize the research on actor model, supervision trees, green threads.".',
  "The fake model served 7 requests, at most 3 at once.",
  "ada: restarts 0",
  "grace: restarts 0",
  "linus: restarts 0",
  "search: restarts 1",
  "writer: restarts 0",
  "",
];

const ZOD_VALIDATION = [
  '{"kind":"accepted","signup":{"email":"ada@example.com","age":36,"plan":"team"}}',
  '{"kind":"rejected","issues":[{"path":"email","message":"Invalid email address"},{"path":"age","message":"Too small: expected number to be >=13"},{"path":"plan","message":"Invalid option: expected one of \\"free\\"|\\"team\\""}]}',
  '{"kind":"rejected","issues":[{"path":"plan","message":"Invalid option: expected one of \\"free\\"|\\"team\\""}]}',
  '{"accepted":1,"rejected":2}',
  "",
].join("\n");

describe("examples", () => {
  for (const host of BOUY_HOSTS) {
    const test = { timeout: TEST_TIMEOUT_MS, skip: !host.available };

    it(`hello prints the expected lines on ${host.name}`, test, async () => {
      const exit = await launch(host, "hello.ts", options);
      expect(exit, exit.stderr).toEqual({ code: 0, signal: null, stdout: HELLO, stderr: "" });
    });

    it(
      `research-team researches, survives a tool crash, and streams on ${host.name}`,
      test,
      async () => {
        const exit = await launch(host, "research-team.ts", options);
        expect(exit.code, exit.stderr).toBe(0);
        expect(exit.stderr).toBe("");
        expect(exit.stdout.split("\n")).toEqual(RESEARCH_TEAM);
      },
    );

    it(
      `zod-validation returns plain results from inside the actor on ${host.name}`,
      test,
      async () => {
        const exit = await launch(host, "zod-validation.ts", options);
        expect(exit, exit.stderr).toEqual({
          code: 0,
          signal: null,
          stdout: ZOD_VALIDATION,
          stderr: "",
        });
      },
    );
  }
});
