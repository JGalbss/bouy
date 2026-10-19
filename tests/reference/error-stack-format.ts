// The stack of an error formats on its first read, with the name, message, and
// code that the error has by then, through Error.prepareStackTrace when the
// program sets it.
import { readFileSync } from "node:fs";

const firstLine = (stack: unknown): string => String(stack).split("\n")[0] ?? "";

const renamed = new Error("before");
renamed.message = "after";
console.log(firstLine(renamed.stack));

try {
  readFileSync({} as string);
} catch (error) {
  console.log(firstLine((error as Error).stack));
}

const captured: { stack?: string } = {};
Error.captureStackTrace(captured);
console.log(firstLine(captured.stack));

Error.prepareStackTrace = (error: Error, frames: unknown) =>
  `${error.message} ${Array.isArray(frames)}`;
console.log(new Error("custom").stack);
Error.prepareStackTrace = undefined;

Error.stackTraceLimit = 0;
console.log(JSON.stringify(new RangeError("no frames").stack));
