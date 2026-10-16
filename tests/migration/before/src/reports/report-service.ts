// Report publishing. This part of the service moved to Effect first: the store and the
// publisher are services, provided by layers, and every failure is typed.
import { type Cause, Console, Context, Data, Effect, Layer, Schedule, Schema } from "effect";
import { sleep } from "../util/async.ts";

const ReportSchema = Schema.Struct({
  requestId: Schema.String,
  topic: Schema.String,
  status: Schema.Literals(["complete", "partial"]),
  summary: Schema.NonEmptyString,
  findings: Schema.Number,
  citations: Schema.Array(Schema.String),
});

export type Report = typeof ReportSchema.Type;

const decodeReport = Schema.decodeUnknownEffect(ReportSchema);

export class InvalidReport extends Schema.TaggedError<InvalidReport>()("InvalidReport", {
  requestId: Schema.String,
  message: Schema.String,
}) {}

export class PublishError extends Data.TaggedError("PublishError")<{
  readonly requestId: string;
  readonly attempt: number;
  readonly reason: string;
}> {}

export interface Receipt {
  readonly requestId: string;
  readonly channel: string;
  readonly attempt: number;
}

export class ReportStore extends Context.Service<
  ReportStore,
  {
    readonly save: (report: Report) => Effect.Effect<void>;
    readonly list: Effect.Effect<ReadonlyArray<Report>>;
  }
>()("research/reports/ReportStore") {
  static readonly layer = Layer.sync(ReportStore, () => {
    const reports = new Map<string, Report>();
    return ReportStore.of({
      save: (report) =>
        Effect.sync(() => {
          reports.set(report.requestId, report);
        }),
      list: Effect.sync(() => [...reports.values()]),
    });
  });
}

export class Publisher extends Context.Service<
  Publisher,
  {
    readonly publish: (report: Report) => Effect.Effect<Receipt, PublishError>;
  }
>()("research/reports/Publisher") {
  /** The team channel webhook. It answers 503 to the first delivery of each report. */
  static readonly layer = Layer.sync(Publisher, () => {
    const deliveries = new Map<string, number>();
    return Publisher.of({
      publish: (report) =>
        Effect.gen(function* () {
          const attempt = (deliveries.get(report.requestId) ?? 0) + 1;
          deliveries.set(report.requestId, attempt);
          yield* Effect.tryPromise({
            try: () => sleep(2),
            catch: (cause) =>
              new PublishError({ requestId: report.requestId, attempt, reason: String(cause) }),
          });
          if (attempt === 1) {
            return yield* new PublishError({
              requestId: report.requestId,
              attempt,
              reason: "503 Service Unavailable",
            });
          }
          return { requestId: report.requestId, channel: "#research", attempt };
        }),
    });
  });
}

export class Reports extends Context.Service<
  Reports,
  {
    readonly submit: (
      input: unknown,
    ) => Effect.Effect<Receipt, InvalidReport | PublishError | Cause.TimeoutError>;
    readonly stored: Effect.Effect<number>;
  }
>()("research/reports/Reports") {
  static readonly layer = Layer.effect(
    Reports,
    Effect.gen(function* () {
      const store = yield* ReportStore;
      const publisher = yield* Publisher;

      const submit = Effect.fn("Reports.submit")(function* (input: unknown) {
        const report = yield* decodeReport(input).pipe(
          Effect.mapError(
            (error) =>
              new InvalidReport({
                requestId: requestIdOf(input),
                message: error.message.replace(/\s*\n\s*/g, " "),
              }),
          ),
        );
        yield* store.save(report);
        return yield* publisher
          .publish(report)
          .pipe(
            Effect.retry({ schedule: Schedule.exponential("5 millis"), times: 3 }),
            Effect.timeout("2 seconds"),
          );
      });

      return Reports.of({ submit, stored: Effect.map(store.list, (reports) => reports.length) });
    }),
  ).pipe(Layer.provide(Layer.mergeAll(ReportStore.layer, Publisher.layer)));
}

function requestIdOf(input: unknown): string {
  if (typeof input === "object" && input !== null && "requestId" in input) {
    return String(input.requestId);
  }
  return "unknown";
}

/** Submits every report, two at a time, and describes what happened to each. */
export const publishAll = (inputs: readonly unknown[]) =>
  Effect.gen(function* () {
    const reports = yield* Reports;
    const lines = yield* Effect.forEach(
      inputs,
      (input) =>
        reports.submit(input).pipe(
          Effect.map(
            (receipt) =>
              `published ${receipt.requestId} to ${receipt.channel} on attempt ${receipt.attempt}`,
          ),
          Effect.catchTag("InvalidReport", (error) =>
            Effect.succeed(`rejected ${error.requestId}: ${error.message}`),
          ),
        ),
      { concurrency: 2 },
    );
    const stored = yield* reports.stored;
    yield* Console.log(`report store holds ${stored} reports`);
    return lines;
  });

/** The Promise boundary for the rest of the service, which does not use Effect. */
export function publishReports(inputs: readonly unknown[]): Promise<string[]> {
  return Effect.runPromise(publishAll(inputs).pipe(Effect.provide(Reports.layer)));
}
