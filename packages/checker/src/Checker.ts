import { resolve } from "node:path";
import { Array as Arr, Context, Effect, Layer, Order } from "effect";
import { Actors } from "./Actors.ts";
import { BouyApi } from "./BouyApi.ts";
import { Boundary } from "./Boundary.ts";
import { formatDiagnostic, type Diagnostic } from "./Diagnostic.ts";
import { FloatingPromises } from "./FloatingPromises.ts";
import { ModuleState } from "./ModuleState.ts";
import { Project, type CheckFailed } from "./Project.ts";

const byLocation = Order.Struct({ file: Order.String, line: Order.Number, column: Order.Number });

export class Checker extends Context.Service<
  Checker,
  {
    check(entry: string): Effect.Effect<ReadonlyArray<Diagnostic>, CheckFailed>;
  }
>()("bouy/checker/Checker") {
  static readonly layer: Layer.Layer<Checker> = Layer.succeed(
    Checker,
    Checker.of({
      check: Effect.fn("Checker.check")(function* (entry: string) {
        const project = yield* Project.load(resolve(entry));
        const typeDiagnostics = project.typeCheck();
        const api = new BouyApi(project);
        const rules = [
          new Boundary(project, api.refClasses),
          new ModuleState(project),
          new FloatingPromises(project),
        ];
        const actorDiagnostics = new Actors(project, api.spawners)
          .find()
          .flatMap((actor) => rules.flatMap((rule) => rule.diagnostics(actor)));
        const unique = new Map(
          [...typeDiagnostics, ...actorDiagnostics].map((diagnostic) => [
            formatDiagnostic(diagnostic),
            diagnostic,
          ]),
        );
        return Arr.sort(unique.values(), byLocation);
      }),
    }),
  );
}
