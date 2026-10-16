import { parentPort, workerData } from "node:worker_threads";
import { Match, Predicate, Schema } from "effect";
import { installLoader } from "../loader/Loader.ts";
import { isActorClass } from "../runtime/Blueprint.ts";
import { LocalBody } from "../runtime/Body.ts";
import { blueprintFor } from "../runtime/Messaging.ts";
import { failureReport, ThreadSetup, ToWorker, type FromWorker } from "./protocol.ts";

const port = parentPort;
if (port === null) throw new Error("bouy's thread host must run inside a worker thread");

const post = (message: Schema.Schema.Type<typeof FromWorker>): void =>
  port.postMessage(message, []);

try {
  const setup = Schema.decodeUnknownSync(ThreadSetup)(workerData);
  installLoader();
  const candidate: unknown = Object(await import(setup.module))[setup.exportName];
  if (!isActorClass(candidate)) {
    throw new TypeError(`${setup.module} does not export a class named ${setup.exportName}`);
  }
  const body = new LocalBody(Reflect.construct(candidate, setup.args), blueprintFor(candidate));
  const decode = Schema.decodeUnknownSync(ToWorker);
  port.on("message", (raw) => {
    Match.valueTags(decode(raw), {
      Ping: ({ at }) => post({ _tag: "Pong", at }),
      Call: ({ id, method, args }) => {
        void (async () => {
          try {
            const value = await body.invoke(method, args);
            if (Predicate.hasProperty(value, Symbol.asyncIterator)) {
              throw new TypeError(`${method} streams, and thread actors do not stream yet`);
            }
            post({ _tag: "Reply", id, value });
          } catch (cause) {
            post({ _tag: "Failed", id, ...failureReport(cause) });
          }
        })();
      },
    });
  });
  post({ _tag: "Ready" });
} catch (cause) {
  post({ _tag: "StartFailed", ...failureReport(cause) });
}
