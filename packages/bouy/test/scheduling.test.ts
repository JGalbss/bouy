import { afterEach, describe, expect, it } from "vitest";
import { pause, tick } from "../src/intrinsics.ts";
import { inspect, shutdown, spawn } from "../src/index.ts";

class Cruncher {
  async crunch(iterations: number): Promise<number> {
    let total = 0;
    for (let index = 0; index < iterations; index += 1) {
      if (tick()) await pause();
      total = (total + index) % 1_000_003;
    }
    return total;
  }
}

class Pinger {
  ping(): number {
    return performance.now();
  }
}

const streamState = { produced: 0, finished: false };

class Producer {
  async *numbers(): AsyncGenerator<number> {
    try {
      for (let value = 0; value < 1_000; value += 1) {
        streamState.produced += 1;
        yield value;
      }
    } finally {
      streamState.finished = true;
    }
  }
}

afterEach(() => shutdown());

describe("scheduling", () => {
  it("keeps other actors responsive while one actor runs a long loop", async () => {
    const cruncher = spawn(Cruncher);
    const pinger = spawn(Pinger);
    const crunching = cruncher.crunch(60_000_000);
    const latencies: Array<number> = [];
    while (latencies.length < 20) {
      const sentAt = performance.now();
      await pinger.ping();
      latencies.push(performance.now() - sentAt);
    }
    await crunching;
    const worst = Math.max(...latencies);
    expect(worst).toBeLessThan(50);
  });

  it("stays stable with ten thousand actors and one hundred thousand messages", async () => {
    const pingers = Array.from({ length: 10_000 }, () => spawn(Pinger));
    const replies = await Promise.all(
      pingers.flatMap((pinger) => Array.from({ length: 10 }, () => pinger.ping())),
    );
    expect(replies).toHaveLength(100_000);
    expect(inspect().filter((actor) => actor.name === "Pinger")).toHaveLength(10_000);
  });
});

describe("streams", () => {
  it("applies backpressure and closes the generator when the consumer stops early", async () => {
    streamState.produced = 0;
    streamState.finished = false;
    const producer = spawn(Producer);
    const received: Array<number> = [];
    for await (const value of producer.numbers()) {
      received.push(value);
      if (received.length === 3) {
        await new Promise((resolve) => setTimeout(resolve, 20));
        expect(streamState.produced).toBeLessThan(40);
        break;
      }
    }
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(streamState.finished).toBe(true);
    expect(streamState.produced).toBeLessThan(1_000);
  });
});
