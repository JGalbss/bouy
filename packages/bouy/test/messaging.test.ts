import { afterEach, describe, expect, it } from "vitest";
import {
  MailboxFull,
  MessageDropped,
  cast,
  self,
  shutdown,
  signal,
  spawn,
  withSignal,
  type Ref,
} from "../src/index.ts";

class Log {
  readonly #entries: Array<string> = [];

  record(entry: string): void {
    this.#entries.push(entry);
  }

  entries(): Array<string> {
    return this.#entries;
  }
}

class Sender {
  async sendAll(log: Ref<Log>, prefix: string, count: number): Promise<void> {
    for (let index = 0; index < count; index += 1) await cast(log).record(`${prefix}${index}`);
  }
}

const releases: Array<() => void> = [];

const openGate = (): void => releases.shift()?.();

const untilHeld = async (): Promise<void> => {
  while (releases.length === 0) await new Promise((resolve) => setImmediate(resolve));
};

class Gate {
  async hold(): Promise<string> {
    await new Promise<void>((resolve) => releases.push(resolve));
    return "released";
  }

  echo(value: string): string {
    return value;
  }
}

class Patient {
  async wait(): Promise<string> {
    const cancellation = signal();
    await new Promise((resolve, reject) => {
      const timer = setTimeout(resolve, 10_000);
      cancellation.addEventListener("abort", () => {
        clearTimeout(timer);
        reject(cancellation.reason);
      });
    });
    return "finished";
  }

  quick(): string {
    return "quick";
  }
}

class Echo {
  async callback(): Promise<string> {
    return self<Echo>(this).nested();
  }

  nested(): string {
    return "nested";
  }

  async *count(limit: number): AsyncGenerator<number> {
    for (let value = 0; value < limit; value += 1) yield value;
  }
}

afterEach(() => shutdown());

describe("message ordering", () => {
  it("delivers messages from one sender in send order", async () => {
    const log = spawn(Log);
    for (let index = 0; index < 500; index += 1) void log.record(`m${index}`);
    const entries = await log.entries();
    expect(entries).toEqual(Array.from({ length: 500 }, (_, index) => `m${index}`));
  });

  it("keeps each sender's order when senders interleave", async () => {
    const log = spawn(Log);
    const senders = ["a", "b", "c"].map((prefix) => ({ prefix, sender: spawn(Sender) }));
    await Promise.all(senders.map(({ prefix, sender }) => sender.sendAll(log, prefix, 200)));
    const entries = await log.entries();
    for (const { prefix } of senders) {
      const own = entries.filter((entry) => entry.startsWith(prefix));
      expect(own).toEqual(Array.from({ length: 200 }, (_, index) => `${prefix}${index}`));
    }
  });
});

describe("mailboxes", () => {
  it("rejects new messages when a reject-policy mailbox is full", async () => {
    const gate = spawn(Gate, { mailbox: { capacity: 2, overflow: "reject" } });
    const held = gate.hold();
    await untilHeld();
    const queued = [gate.echo("1"), gate.echo("2")];
    await expect(gate.echo("3")).rejects.toBeInstanceOf(MailboxFull);
    openGate();
    expect(await held).toBe("released");
    expect(await Promise.all(queued)).toEqual(["1", "2"]);
  });

  it("drops the oldest message under the drop-oldest policy", async () => {
    const gate = spawn(Gate, { mailbox: { capacity: 2, overflow: "drop-oldest" } });
    const held = gate.hold();
    await untilHeld();
    const oldest = gate.echo("1");
    const kept = [gate.echo("2"), gate.echo("3")];
    await expect(oldest).rejects.toBeInstanceOf(MessageDropped);
    openGate();
    await held;
    expect(await Promise.all(kept)).toEqual(["2", "3"]);
  });

  it("makes senders wait under backpressure without exceeding capacity", async () => {
    const gate = spawn(Gate, { mailbox: { capacity: 4, overflow: "backpressure" } });
    const held = gate.hold();
    await untilHeld();
    const waiting = Array.from({ length: 20 }, (_, index) => gate.echo(String(index)));
    openGate();
    await held;
    expect(await Promise.all(waiting)).toEqual(
      Array.from({ length: 20 }, (_, index) => String(index)),
    );
  });
});

describe("cancellation", () => {
  it("aborts the running call and leaves the actor and other actors working", async () => {
    const patient = spawn(Patient);
    const bystander = spawn(Patient);
    const controller = new AbortController();
    const pending = withSignal(controller.signal, () => patient.wait());
    await new Promise((resolve) => setTimeout(resolve, 5));
    controller.abort();
    await expect(pending).rejects.toThrow();
    expect(await patient.quick()).toBe("quick");
    expect(await bystander.quick()).toBe("quick");
  });

  it("never runs a call cancelled while it waits in the mailbox", async () => {
    const gate = spawn(Gate);
    const held = gate.hold();
    await untilHeld();
    const controller = new AbortController();
    const queued = withSignal(controller.signal, () => gate.echo("never"));
    controller.abort();
    await expect(queued).rejects.toThrow();
    openGate();
    expect(await held).toBe("released");
  });
});

describe("calls between actors", () => {
  it("rejects a call that would wait on its own call chain", async () => {
    const echo = spawn(Echo);
    await expect(echo.callback()).rejects.toMatchObject({ cause: { name: "CallCycle" } });
    expect(await echo.nested()).toBe("nested");
  });

  it("streams results from an async generator method", async () => {
    const echo = spawn(Echo);
    const values: Array<number> = [];
    for await (const value of echo.count(5)) values.push(value);
    expect(values).toEqual([0, 1, 2, 3, 4]);
  });
});
