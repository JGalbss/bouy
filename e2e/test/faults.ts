import { EventEmitter } from "node:events";
import { setTimeout as sleep } from "node:timers/promises";
import { inspect, shutdown, spawn } from "bouy";
import { z } from "zod";

const DEADLINE_MS = 10_000;
const POLL_MS = 5;
const PINGS_AFTER_FAULT = 5;

const Fault = z.enum(["timer", "microtask", "emitter", "shared-emitter", "promise"]);
type Fault = z.infer<typeof Fault>;

const fault = Fault.parse(process.env["FAULT"]);

const bell = new EventEmitter();

const throwLater: Record<Fault, () => void> = {
  timer: () => {
    setTimeout(() => {
      throw new Error("timer fault");
    }, 0);
  },
  microtask: () => {
    queueMicrotask(() => {
      throw new Error("microtask fault");
    });
  },
  emitter: () => {
    const emitter = new EventEmitter();
    emitter.on("tick", () => {
      throw new Error("emitter fault");
    });
    setTimeout(() => emitter.emit("tick"), 0);
  },
  "shared-emitter": () => {
    bell.on("ring", () => {
      throw new Error("shared-emitter fault");
    });
  },
  promise: () => {
    void Promise.resolve().then(() => {
      throw new Error("promise fault");
    });
  },
};

class Faulty {
  #armed = 0;

  arm(kind: Fault): number {
    this.#armed += 1;
    throwLater[kind]();
    return this.#armed;
  }

  armed(): number {
    return this.#armed;
  }
}

class Steady {
  #answered = 0;

  ping(): number {
    this.#answered += 1;
    return this.#answered;
  }

  ringLater(): void {
    setTimeout(() => bell.emit("ring"), 0);
  }
}

const faulty = spawn(Faulty, { name: "faulty" });
const steady = spawn(Steady, { name: "steady" });

const restartCount = (name: string): number =>
  inspect().find((actor) => actor.name === name)?.restarts ?? -1;

const armedBefore = await faulty.arm(fault);
await steady.ringLater();
const replies: Array<number> = [];
const startedAt = performance.now();
while (restartCount("faulty") + restartCount("steady") === 0 && process.exitCode !== 1) {
  if (performance.now() - startedAt > DEADLINE_MS) throw new Error(`no outcome for ${fault}`);
  replies.push(await steady.ping());
  await sleep(POLL_MS);
}
for (let index = 0; index < PINGS_AFTER_FAULT; index += 1) replies.push(await steady.ping());

console.log(
  JSON.stringify({
    fault,
    armedBefore,
    armedAfter: await faulty.armed(),
    faultyRestarts: restartCount("faulty"),
    steadyRestarts: restartCount("steady"),
    steadyRepliesInOrder: replies.every((reply, index) => reply === index + 1),
    steadyReplies: replies.length,
    exitCode: process.exitCode ?? 0,
  }),
);
await shutdown();
