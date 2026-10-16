#!/usr/bin/env node
import { resolve } from "node:path";
import { NodeRuntime, NodeServices } from "@effect/platform-node";
import { Console, Effect, Schema } from "effect";
import { Argument, Command, Flag } from "effect/cli";
import { shutdown } from "../index.ts";
import { entryUrl, installLoader } from "../loader/Loader.ts";

class EntryFailed extends Schema.TaggedError<EntryFailed>()("EntryFailed", {
  entry: Schema.String,
  cause: Schema.Defect(),
}) {
  override get message(): string {
    return `${this.entry} failed while loading: ${String(this.cause)}`;
  }
}

class ChecksFailed extends Schema.TaggedError<ChecksFailed>()("ChecksFailed", {
  errors: Schema.Number,
}) {
  override get message(): string {
    return `bouy check found ${this.errors} error(s)`;
  }
}

const entry = Argument.String("entry").pipe(
  Argument.withDescription("The TypeScript module to run"),
);

const checkEntry = Effect.fn("Cli.checkEntry")(function* (path: string) {
  const { Checker, formatDiagnostic } = yield* Effect.promise(() => import("@bouy/checker"));
  const diagnostics = yield* Checker.use((checker) => checker.check(path)).pipe(
    Effect.provide(Checker.layer),
  );
  yield* Effect.forEach(diagnostics, (diagnostic) => Console.error(formatDiagnostic(diagnostic)), {
    discard: true,
  });
  const errors = diagnostics.filter((diagnostic) => diagnostic.severity === "error").length;
  if (errors > 0) yield* new ChecksFailed({ errors });
});

const stopAllActors = (): void => {
  void shutdown().finally(() => process.exit(130));
};

const run = Command.make(
  "run",
  {
    entry,
    args: Argument.String("args").pipe(
      Argument.withDescription(
        "Arguments for the program; put -- before arguments that start with -",
      ),
      Argument.variadic(),
    ),
    check: Flag.Boolean("check").pipe(
      Flag.withDescription("Run the actor isolation checks before the program starts"),
      Flag.withDefault(false),
    ),
  },
  Effect.fn("Cli.run")(function* (options) {
    const path = resolve(options.entry);
    if (options.check) yield* checkEntry(path);
    installLoader();
    process.argv = [process.argv[0] ?? process.execPath, path, ...options.args];
    yield* Effect.tryPromise({
      try: () => import(entryUrl(path)),
      catch: (cause) => new EntryFailed({ entry: path, cause }),
    });
    process.once("SIGINT", stopAllActors);
    process.once("SIGTERM", stopAllActors);
  }),
).pipe(Command.withDescription("Compile and run a TypeScript program whose agents run as actors"));

const check = Command.make(
  "check",
  { entry },
  Effect.fn("Cli.check")(function* (options) {
    yield* checkEntry(resolve(options.entry));
    yield* Console.log("No actor isolation errors.");
  }),
).pipe(Command.withDescription("Type-check a program and check its actor boundaries"));

Command.make("bouy").pipe(
  Command.withSubcommands([run, check]),
  Command.run({ version: "0.1.0" }),
  Effect.catchTag("ChecksFailed", (failure) =>
    Console.error(failure.message).pipe(Effect.andThen(Effect.sync(() => process.exit(1)))),
  ),
  Effect.provide(NodeServices.layer),
  NodeRuntime.runMain,
);
