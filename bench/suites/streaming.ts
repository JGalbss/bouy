import { spawn } from "bouy";
import { median, nanosecondsSince, repeatInSequence } from "../evidence/measure.ts";
import { report } from "../suite.ts";

const ITEMS = 100_000;
const ROUNDS = 5;
const EXPECTED_TOTAL = (ITEMS * (ITEMS - 1)) / 2;

class Feed {
  async *count(limit: number): AsyncGenerator<number> {
    for (let index = 0; index < limit; index += 1) yield index;
  }
}

const itemsPerSecond = async (items: AsyncIterable<number>): Promise<number> => {
  const start = process.hrtime.bigint();
  let total = 0;
  for await (const item of items) total += item;
  const elapsed = nanosecondsSince(start);
  if (total !== EXPECTED_TOTAL) throw new Error(`The stream summed to ${total}.`);
  return (ITEMS * 1e9) / elapsed;
};

const feed = spawn(Feed);
const local = new Feed();
const bouyRates: Array<number> = [];
const plainRates: Array<number> = [];
await repeatInSequence(ROUNDS, async () => {
  bouyRates.push(await itemsPerSecond(feed.count(ITEMS)));
  plainRates.push(await itemsPerSecond(local.count(ITEMS)));
});

report({
  bouy: { itemsPerSecond: median(bouyRates) },
  plain: { itemsPerSecond: median(plainRates) },
});
