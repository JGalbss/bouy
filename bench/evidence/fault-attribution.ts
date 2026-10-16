import { AsyncLocalStorage } from "node:async_hooks";
import { EventEmitter, EventEmitterAsyncResource } from "node:events";
import { readFile } from "node:fs";

const REPORT_AFTER_MS = 500;

const FAULTS = [
  "timer",
  "microtask",
  "floating-promise",
  "emitter",
  "io-callback",
  "cross-actor-emitter",
  "cross-actor-async-resource",
] as const;

interface Observation {
  readonly event: string;
  readonly storeAtEvent: string;
}

const storage = new AsyncLocalStorage<string>();
const storeAtThrow = new Map<string, string>();
const observations = new Map<string, Observation>();

const fail = (fault: string): never => {
  storeAtThrow.set(fault, storage.getStore() ?? "none");
  throw new Error(fault);
};

process.on("uncaughtException", (error) => {
  observations.set(error.message, {
    event: "uncaughtException",
    storeAtEvent: storage.getStore() ?? "none",
  });
});

process.on("unhandledRejection", (reason) => {
  observations.set(reason instanceof Error ? reason.message : String(reason), {
    event: "unhandledRejection",
    storeAtEvent: storage.getStore() ?? "none",
  });
});

storage.run("timer", () => {
  setTimeout(() => fail("timer"), 0);
});

storage.run("microtask", () => {
  queueMicrotask(() => fail("microtask"));
});

storage.run("floating-promise", () => {
  void Promise.resolve().then(() => fail("floating-promise"));
});

storage.run("emitter", () => {
  const emitter = new EventEmitter();
  emitter.on("tick", () => fail("emitter"));
  setTimeout(() => emitter.emit("tick"), 0);
});

storage.run("io-callback", () => {
  readFile(import.meta.filename, () => fail("io-callback"));
});

const sharedEmitter = storage.run("listener-actor", () => {
  const emitter = new EventEmitter();
  emitter.on("tick", () => fail("cross-actor-emitter"));
  return emitter;
});

const sharedResource = storage.run("listener-actor", () => {
  const emitter = new EventEmitterAsyncResource({ name: "bouy-evidence" });
  emitter.on("tick", () => fail("cross-actor-async-resource"));
  return emitter;
});

storage.run("emitting-actor", () => {
  setTimeout(() => sharedEmitter.emit("tick"), 0);
  setTimeout(() => sharedResource.emit("tick"), 0);
});

setTimeout(() => {
  console.log(
    JSON.stringify(
      Object.fromEntries(
        FAULTS.flatMap((fault) => [
          [`${fault}.storeAtThrow`, storeAtThrow.get(fault) ?? "not thrown"],
          [`${fault}.event`, observations.get(fault)?.event ?? "not observed"],
          [`${fault}.storeAtEvent`, observations.get(fault)?.storeAtEvent ?? "not observed"],
        ]),
      ),
    ),
  );
}, REPORT_AFTER_MS);
