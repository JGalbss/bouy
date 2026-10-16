import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import {
  BOUY_HOSTS,
  PROGRAMS,
  launch,
  PLAIN_NODE,
  CHILD_TIMEOUT_MS,
  TEST_TIMEOUT_MS,
} from "./hosts.ts";

const COMPATIBILITY_NOTE = new URL("../docs/npm-compatibility.md", import.meta.url);
const EQUIVALENCE_ROW =
  /^\| `(?<name>[^`]+)` +\| (?<version>[^ |]+) +\|.+\| `e2e\/npm-equivalence\.test\.ts` +\|$/gmu;

const Manifest = z.object({ version: z.string() });
const DocumentedVersions = z.record(z.string(), z.string());

const documentedVersions = DocumentedVersions.parse(
  Object.fromEntries(
    Array.from(readFileSync(COMPATIBILITY_NOTE, "utf8").matchAll(EQUIVALENCE_ROW), (row) => [
      row.groups?.["name"],
      row.groups?.["version"],
    ]),
  ),
);

const fromE2e = createRequire(import.meta.url);
const fromAi = createRequire(fromE2e.resolve("ai"));

const installedVersion = (resolver: NodeJS.Require, name: string): string =>
  Manifest.parse(resolver(`${name}/package.json`)).version;

const options = { cwd: PROGRAMS, timeoutMs: CHILD_TIMEOUT_MS };

describe("npm equivalence between plain node and actors", () => {
  const plainRun = launch(PLAIN_NODE, "npm-plain.ts", options);

  it("runs against the package versions that docs/npm-compatibility.md names", () => {
    expect({
      zod: installedVersion(fromE2e, "zod"),
      ai: installedVersion(fromE2e, "ai"),
      "@ai-sdk/openai": installedVersion(fromE2e, "@ai-sdk/openai"),
      "@ai-sdk/provider-utils": installedVersion(fromAi, "@ai-sdk/provider-utils"),
      "@ai-sdk/provider": installedVersion(fromAi, "@ai-sdk/provider"),
    }).toEqual(documentedVersions);
  });

  it(
    "prints the scenario report as plain node code without actors",
    { timeout: TEST_TIMEOUT_MS },
    async () => {
      const plain = await plainRun;
      expect(plain.code, plain.stderr).toBe(0);
      expect(plain.stderr).toBe("");
      expect(JSON.parse(plain.stdout)).toMatchObject({
        zod: {
          parse: { id: "order-1", quantity: 2, tags: [] },
          parseFailure: { threw: true, isZodError: true },
          safeParse: { success: true },
          safeParseFailure: { success: false },
        },
        generateText: { text: 'Answer about "What is an actor?".', finishReason: "stop" },
        streamText: { text: 'Answer about "Explain supervision trees.".', finishReason: "stop" },
        generateTextToolCall: {
          steps: [{ finishReason: "tool-calls", toolCalls: [{ toolName: "weather" }] }, {}],
        },
        streamTextToolCall: {
          steps: [{ finishReason: "tool-calls", toolCalls: [{ toolName: "weather" }] }, {}],
        },
      });
    },
  );

  for (const host of BOUY_HOSTS) {
    const test = { timeout: TEST_TIMEOUT_MS, skip: !host.available };

    it(`prints the same canonical JSON from three actors on ${host.name}`, test, async () => {
      const [plain, exit] = await Promise.all([plainRun, launch(host, "npm-actors.ts", options)]);
      expect(exit.code, exit.stderr).toBe(0);
      expect(exit.stderr).toBe("");
      expect(exit.stdout).toBe(plain.stdout);
    });
  }
});
