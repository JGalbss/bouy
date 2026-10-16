import { Schema } from "effect";
import { SendableValue } from "../runtime/Sendable.ts";

const FailureFields = {
  name: Schema.String,
  message: Schema.String,
  stack: Schema.optional(Schema.String),
};

export const ThreadSetup = Schema.Struct({
  module: Schema.String,
  exportName: Schema.String,
  args: Schema.Array(SendableValue),
});

export const ToWorker = Schema.Union([
  Schema.TaggedStruct("Call", {
    id: Schema.Number,
    method: Schema.String,
    args: Schema.Array(SendableValue),
  }),
  Schema.TaggedStruct("Ping", { at: Schema.Number }),
]);

export const FromWorker = Schema.Union([
  Schema.TaggedStruct("Ready", {}),
  Schema.TaggedStruct("StartFailed", FailureFields),
  Schema.TaggedStruct("Reply", { id: Schema.Number, value: SendableValue }),
  Schema.TaggedStruct("Failed", { id: Schema.Number, ...FailureFields }),
  Schema.TaggedStruct("Pong", { at: Schema.Number }),
]);

export type FailureReport = Schema.Struct.Type<typeof FailureFields>;

export const failureReport = (cause: unknown): FailureReport => {
  if (cause instanceof Error) {
    const report = { name: cause.name, message: cause.message };
    if (cause.stack === undefined) return report;
    return { ...report, stack: cause.stack };
  }
  return { name: "Error", message: String(cause) };
};

export const errorFrom = (report: FailureReport): Error => {
  const error = new Error(report.message);
  Object.defineProperties(error, {
    name: { value: report.name, writable: true, configurable: true },
    stack: { value: report.stack ?? error.stack, writable: true, configurable: true },
  });
  return error;
};
