import { setTimeout as sleep } from "node:timers/promises";
import { spawn } from "bouy";
import { median, nanosecondsSince, repeatInSequence } from "../evidence/measure.ts";
import { report } from "../suite.ts";

const AGENTS = 1_000;
const TOOL_CALLS = 5;
const ROUNDS = 30;

const research = async (): Promise<number> => {
  await repeatInSequence(TOOL_CALLS, () => sleep(1));
  return TOOL_CALLS;
};

class Agent {
  research(): Promise<number> {
    return research();
  }
}

const agents = Array.from({ length: AGENTS }, () => spawn(Agent));

const millisecondsFor = async (fanOut: () => Promise<ReadonlyArray<number>>): Promise<number> => {
  const start = process.hrtime.bigint();
  const finished = await fanOut();
  if (finished.length !== AGENTS) throw new Error(`Only ${finished.length} agents finished.`);
  return nanosecondsSince(start) / 1e6;
};

const plainMilliseconds: Array<number> = [];
const bouyMilliseconds: Array<number> = [];
await repeatInSequence(ROUNDS, async () => {
  plainMilliseconds.push(
    await millisecondsFor(() => Promise.all(Array.from({ length: AGENTS }, research))),
  );
  bouyMilliseconds.push(
    await millisecondsFor(() => Promise.all(agents.map((agent) => agent.research()))),
  );
});

const plainWallMs = median(plainMilliseconds);
const bouyWallMs = median(bouyMilliseconds);

report({
  plain: { wallMs: plainWallMs },
  bouy: { wallMs: bouyWallMs },
  overhead: { usPerCall: ((bouyWallMs - plainWallMs) * 1e3) / AGENTS },
});
