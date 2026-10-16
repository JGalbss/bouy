import { describe, expect, it } from "vitest";
import { BOUY_HOSTS, CHILD_TIMEOUT_MS, PROGRAMS, launch, TEST_TIMEOUT_MS } from "./hosts.ts";

const options = { cwd: PROGRAMS, timeoutMs: CHILD_TIMEOUT_MS };

const CANNOT_CROSS = "cannot cross an actor boundary. Send plain data or an actor ref.";

describe("state isolation across the actor boundary", () => {
  for (const host of BOUY_HOSTS) {
    const test = { timeout: TEST_TIMEOUT_MS, skip: !host.available };

    it(
      `keeps the actor's copy when the sender mutates, and names what cannot cross, on ${host.name}`,
      test,
      async () => {
        const exit = await launch(host, "isolation.ts", options);
        expect(exit.code, exit.stderr).toBe(0);
        expect(JSON.parse(exit.stdout)).toEqual({
          sent: { text: "changed by the sender", tags: ["draft", "changed by the sender"] },
          stored: { text: "original", tags: ["draft"] },
          rejection: {
            isNotSendable: true,
            name: "NotSendable",
            message: `a function at [0][meta][render] ${CANNOT_CROSS}`,
          },
          notesAfterRejection: 2,
          libraryObjects: {
            schema: `an instance of ZodObject at [0] ${CANNOT_CROSS}`,
            model: `an instance of OpenAIChatLanguageModel at [0] ${CANNOT_CROSS}`,
          },
          thrownLibraryError: {
            isActorFailed: true,
            causeName: "ZodError",
            causeIsZodError: false,
          },
        });
      },
    );

    it(
      `shares a package's module-level state between actors, here zod's global config, on ${host.name}`,
      test,
      async () => {
        const exit = await launch(host, "shared-state.ts", options);
        expect(exit.code, exit.stderr).toBe(0);
        expect(JSON.parse(exit.stdout)).toEqual({
          before: "Too small: expected number to be >=18",
          after: "set by another actor",
        });
      },
    );
  }
});
