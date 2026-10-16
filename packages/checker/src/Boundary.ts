import { Array as Arr, Option } from "effect";
import ts from "typescript";
import { className, type Actor } from "./Actors.ts";
import { diagnosticAt, type Diagnostic } from "./Diagnostic.ts";
import type { Project } from "./Project.ts";
import { Sendable, type Refusal } from "./Sendable.ts";

const THEN = "then";

const REMEDIES: Readonly<Record<Refusal["kind"], string>> = {
  refused:
    "Every value that crosses an actor boundary is copied, so it must be plain data or an actor ref.",
  unverifiable: "Give it a concrete Sendable type.",
};

interface Method {
  readonly name: string;
  readonly label: string;
  readonly implementation: ts.MethodDeclaration;
  readonly signatures: ReadonlyArray<ts.Signature>;
  readonly streams: boolean;
}

export class Boundary {
  readonly #project: Project;
  readonly #sendable: Sendable;

  constructor(project: Project, refClasses: ReadonlySet<ts.Symbol>) {
    this.#project = project;
    this.#sendable = new Sendable(project, refClasses);
  }

  diagnostics(actor: Actor): ReadonlyArray<Diagnostic> {
    return this.#checkThen(actor).concat(
      this.#findPublicMethods(actor).flatMap((method) =>
        this.#checkParameters(method).concat(
          this.#checkResults(method),
          this.#checkStreaming(method),
        ),
      ),
    );
  }

  #checkThen(actor: Actor): ReadonlyArray<Diagnostic> {
    const then = this.#project.checker.getPropertyOfType(actor.instance, THEN);
    if (then === undefined || this.#findImplementation(then).length === 0) return [];
    return (then.declarations ?? []).slice(0, 1).map((declaration) =>
      diagnosticAt(ts.getNameOfDeclaration(declaration) ?? declaration, {
        code: "BOUY105",
        severity: "error",
        message: `${className(actor.declaration)} has a method named then, so every ref to it looks like a promise and await calls that method. Rename the method.`,
      }),
    );
  }

  #findPublicMethods(actor: Actor): ReadonlyArray<Method> {
    const checker = this.#project.checker;
    return checker.getPropertiesOfType(actor.instance).flatMap((property) =>
      this.#findImplementation(property)
        .filter((implementation) => this.#isPublic(implementation))
        .map((implementation) => ({
          name: property.name,
          label: `${className(actor.declaration)}.${property.name}`,
          implementation,
          signatures: checker.getTypeOfSymbol(property).getCallSignatures(),
          streams: this.#isStream(implementation),
        })),
    );
  }

  #findImplementation(method: ts.Symbol): ReadonlyArray<ts.MethodDeclaration> {
    return (method.declarations ?? [])
      .filter(ts.isMethodDeclaration)
      .filter((declaration) => declaration.body !== undefined && this.#project.owns(declaration))
      .slice(0, 1);
  }

  #isPublic(method: ts.MethodDeclaration): boolean {
    const name = method.name;
    if (ts.isPrivateIdentifier(name)) return false;
    if ((ts.getCombinedModifierFlags(method) & ts.ModifierFlags.Private) !== 0) return false;
    if (!ts.isComputedPropertyName(name)) return true;
    const key = this.#project.checker.getTypeAtLocation(name.expression);
    return (key.flags & ts.TypeFlags.ESSymbolLike) === 0;
  }

  #isStream(method: ts.MethodDeclaration): boolean {
    const isAsync = (ts.getCombinedModifierFlags(method) & ts.ModifierFlags.Async) !== 0;
    return isAsync && method.asteriskToken !== undefined;
  }

  #checkParameters(method: Method): ReadonlyArray<Diagnostic> {
    const checker = this.#project.checker;
    return method.signatures.flatMap((signature) =>
      signature.getParameters().flatMap((parameter, position) =>
        Arr.fromNullishOr(parameter.valueDeclaration)
          .filter(ts.isParameter)
          .flatMap((declaration) =>
            Option.toArray(
              Option.map(this.#sendable.check(checker.getTypeOfSymbol(parameter)), (refusal) =>
                diagnosticAt(declaration, {
                  code: "BOUY101",
                  severity: "error",
                  message: `The ${this.#nameParameter(declaration, position)} of ${method.label} is not Sendable: ${refusal.explanation}. ${REMEDIES[refusal.kind]}`,
                }),
              ),
            ),
          ),
      ),
    );
  }

  #nameParameter(declaration: ts.ParameterDeclaration, position: number): string {
    if (ts.isIdentifier(declaration.name)) return `parameter ${declaration.name.text}`;
    return `parameter at position ${position + 1}`;
  }

  #checkResults(method: Method): ReadonlyArray<Diagnostic> {
    return method.signatures.flatMap((signature) => {
      const location = this.#locateResult(method, signature);
      const returned = signature.getReturnType();
      if (method.streams) {
        return this.#project
          .typeArguments(returned)
          .slice(0, 1)
          .flatMap((yielded) => this.#refuseResult(`${method.label} yields`, location, yielded));
      }
      const value = this.#project.unwrapPromise(returned);
      return this.#refuseResult(`${method.label} returns`, location, value);
    });
  }

  #refuseResult(subject: string, location: ts.Node, type: ts.Type): ReadonlyArray<Diagnostic> {
    return Option.toArray(
      Option.map(this.#sendable.check(type), (refusal) =>
        diagnosticAt(location, {
          code: "BOUY102",
          severity: "error",
          message: `${subject} a value that is not Sendable: ${refusal.explanation}. ${REMEDIES[refusal.kind]}`,
        }),
      ),
    );
  }

  #checkStreaming(method: Method): ReadonlyArray<Diagnostic> {
    if (method.streams) return [];
    return method.signatures
      .filter((signature) =>
        this.#project.isAsyncIterable(this.#project.unwrapPromise(signature.getReturnType())),
      )
      .map((signature) =>
        diagnosticAt(this.#locateResult(method, signature), {
          code: "BOUY106",
          severity: "warning",
          message: `${method.label} returns an async iterable but is not an async generator method, so its ref cannot stream it. Write it as an async generator method, async *${method.name}(), so it streams.`,
        }),
      );
  }

  #locateResult(method: Method, signature: ts.Signature): ts.Node {
    return ts.getNameOfDeclaration(signature.getDeclaration()) ?? method.implementation.name;
  }
}
