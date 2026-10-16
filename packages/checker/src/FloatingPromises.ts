import ts from "typescript";
import { instanceMembers, memberLabel, type Actor } from "./Actors.ts";
import { diagnosticAt, type Diagnostic } from "./Diagnostic.ts";
import type { Project } from "./Project.ts";
import { descendants, isAssignment, unwrap } from "./Syntax.ts";

const OUTLIVES_TURN = "The work can outlive the turn and interleave with the next message.";
const DROPPED = `starts a promise that it does not await. ${OUTLIVES_TURN} Await it, return it, or discard it with void.`;
const PASSED = `passes a function that returns a promise to a caller that ignores the result. ${OUTLIVES_TURN} Await the work in the method instead, for example with for...of or Promise.all.`;

export class FloatingPromises {
  readonly #project: Project;

  constructor(project: Project) {
    this.#project = project;
  }

  diagnostics(actor: Actor): ReadonlyArray<Diagnostic> {
    return actor.classes.flatMap((declaration) =>
      instanceMembers(declaration).flatMap((member) => {
        const label = memberLabel(declaration, member);
        return descendants(member).flatMap((node) =>
          this.#findMisuse(node).map((misuse) =>
            diagnosticAt(node, {
              code: "BOUY104",
              severity: "warning",
              message: `${label} ${misuse}`,
            }),
          ),
        );
      }),
    );
  }

  #findMisuse(node: ts.Node): ReadonlyArray<string> {
    if (this.#dropsPromise(node)) return [DROPPED];
    if (this.#returnsPromiseToVoid(node)) return [PASSED];
    return [];
  }

  #dropsPromise(node: ts.Node): boolean {
    const checker = this.#project.checker;
    if (ts.isAwaitExpression(node)) {
      return this.#isPromiseList(checker.getTypeAtLocation(node.expression));
    }
    if (!ts.isExpressionStatement(node)) return false;
    const expression = unwrap(node.expression);
    if (isAssignment(expression) || ts.isAwaitExpression(expression)) return false;
    const type = checker.getTypeAtLocation(expression);
    return this.#project.isThenable(type) || this.#isPromiseList(type);
  }

  #returnsPromiseToVoid(node: ts.Node): boolean {
    if (!ts.isArrowFunction(node) && !ts.isFunctionExpression(node)) return false;
    const checker = this.#project.checker;
    const returned = checker.getSignatureFromDeclaration(node)?.getReturnType();
    if (returned === undefined || !this.#project.isThenable(returned)) return false;
    return (checker.getContextualType(node)?.getCallSignatures() ?? []).some(
      (expected) => (expected.getReturnType().flags & ts.TypeFlags.Void) !== 0,
    );
  }

  #isPromiseList(type: ts.Type): boolean {
    const checker = this.#project.checker;
    if (!checker.isArrayType(type) && !checker.isTupleType(type)) return false;
    return this.#project.typeArguments(type).some((element) => this.#project.isThenable(element));
  }
}
