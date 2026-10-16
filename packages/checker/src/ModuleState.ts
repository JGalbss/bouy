import { Array as Arr, Option, Result } from "effect";
import ts from "typescript";
import { instanceMembers, memberLabel, type Actor } from "./Actors.ts";
import { diagnosticAt, type Diagnostic } from "./Diagnostic.ts";
import type { Project } from "./Project.ts";
import { descendants, isAssignment, unwrap } from "./Syntax.ts";

const CONSTANT = ts.NodeFlags.Const | ts.NodeFlags.Using;
const MUTABLE_CONSTRUCTORS: ReadonlySet<string> = new Set(["Map", "Set", "Array"]);
const MUTATORS: ReadonlySet<string> = new Set([
  "push",
  "pop",
  "shift",
  "unshift",
  "splice",
  "set",
  "delete",
  "add",
  "clear",
  "sort",
  "reverse",
  "fill",
]);
const ELEMENT_LOOKUPS: ReadonlySet<string> = new Set(["get", "at", "find", "findLast"]);
const STEPS: ReadonlySet<ts.SyntaxKind> = new Set([
  ts.SyntaxKind.PlusPlusToken,
  ts.SyntaxKind.MinusMinusToken,
]);
const SHARED_STATE =
  "That binding is mutable state, and every actor in a thread shares module state, so actors see each other's changes. Keep the state in an actor field.";

type Verb = "reads" | "writes";

interface Touch {
  readonly binding: ts.Symbol;
  readonly verb: Verb;
}

interface Use extends Touch {
  readonly node: ts.Node;
  readonly callee: Option.Option<string>;
}

type Callable = ts.FunctionDeclaration | ts.ArrowFunction | ts.FunctionExpression;

export class ModuleState {
  readonly #project: Project;
  readonly #mutable: ReadonlySet<ts.Symbol>;
  readonly #touchesByFunction = new Map<Callable, ReadonlyArray<Touch>>();

  constructor(project: Project) {
    this.#project = project;
    const declarationLists = project.sources
      .flatMap((file) => file.statements)
      .filter(ts.isVariableStatement)
      .map((statement) => statement.declarationList);
    const [variables, constants] = Arr.partition(declarationLists, (list) => {
      if ((list.flags & CONSTANT) === 0) return Result.succeed(list);
      return Result.fail(list);
    });
    const mutated = new Set(
      project.nodes
        .flatMap((node) => this.#mutationTargets(node))
        .flatMap((target) => Arr.fromNullishOr(project.symbolAt(target))),
    );
    this.#mutable = new Set([
      ...variables
        .flatMap((list) => list.declarations)
        .flatMap((declaration) => this.#bindings(declaration.name)),
      ...constants
        .flatMap((list) => list.declarations)
        .filter((declaration) => this.#holdsContainer(declaration.initializer))
        .flatMap((declaration) => this.#bindings(declaration.name))
        .filter((binding) => mutated.has(binding)),
    ]);
  }

  diagnostics(actor: Actor): ReadonlyArray<Diagnostic> {
    return actor.classes.flatMap((declaration) =>
      instanceMembers(declaration).flatMap((member) => {
        const label = memberLabel(declaration, member);
        return this.#findUses(descendants(member)).map((use) =>
          diagnosticAt(use.node, {
            code: "BOUY103",
            severity: "error",
            message: this.#explain(label, use),
          }),
        );
      }),
    );
  }

  #findUses(nodes: ReadonlyArray<ts.Node>): ReadonlyArray<Use> {
    const uses = [...this.#findDirectUses(nodes), ...this.#findCallUses(nodes)];
    return Arr.dedupeWith(
      [
        ...uses.filter((use) => use.verb === "writes"),
        ...uses.filter((use) => use.verb === "reads"),
      ],
      (first, second) => first.binding === second.binding,
    );
  }

  #findDirectUses(nodes: ReadonlyArray<ts.Node>): ReadonlyArray<Use> {
    const written = new Set(nodes.flatMap((node) => this.#mutationTargets(node)));
    const identifiers = nodes
      .filter(ts.isIdentifier)
      .filter((identifier) => ts.findAncestor(identifier, ts.isTypeQueryNode) === undefined);
    return [
      ...this.#useAll(
        identifiers.filter((identifier) => written.has(identifier)),
        "writes",
      ),
      ...this.#useAll(
        identifiers.filter((identifier) => !written.has(identifier)),
        "reads",
      ),
    ];
  }

  #useAll(identifiers: ReadonlyArray<ts.Identifier>, verb: Verb): ReadonlyArray<Use> {
    return identifiers.flatMap((identifier) =>
      Arr.fromNullishOr(this.#project.symbolAt(identifier))
        .filter((binding) => this.#mutable.has(binding))
        .map((binding) => ({ binding, verb, node: identifier, callee: Option.none() })),
    );
  }

  #findCallUses(nodes: ReadonlyArray<ts.Node>): ReadonlyArray<Use> {
    return nodes.filter(ts.isCallExpression).flatMap((call) =>
      this.#findCallee(call).flatMap((callee) =>
        this.#findTouches(callee).map((touch) => ({
          binding: touch.binding,
          verb: touch.verb,
          node: call,
          callee: Option.some(call.expression.getText()),
        })),
      ),
    );
  }

  #findCallee(call: ts.CallExpression): ReadonlyArray<Callable> {
    const declaration = this.#project.checker.getResolvedSignature(call)?.getDeclaration();
    if (declaration === undefined || !this.#project.owns(declaration)) return [];
    if (
      ts.isFunctionDeclaration(declaration) ||
      ts.isArrowFunction(declaration) ||
      ts.isFunctionExpression(declaration)
    ) {
      return [declaration];
    }
    return [];
  }

  #findTouches(callee: Callable): ReadonlyArray<Touch> {
    const known = this.#touchesByFunction.get(callee);
    if (known !== undefined) return known;
    this.#touchesByFunction.set(callee, []);
    const touches = this.#findUses(descendants(callee));
    this.#touchesByFunction.set(callee, touches);
    return touches;
  }

  #explain(label: string, use: Use): string {
    const access = `${use.verb} the module-level binding ${use.binding.name}. ${SHARED_STATE}`;
    return Option.match(use.callee, {
      onNone: () => `${label} ${access}`,
      onSome: (callee) => `${label} calls ${callee}, which ${access}`,
    });
  }

  #bindings(name: ts.BindingName): ReadonlyArray<ts.Symbol> {
    if (ts.isIdentifier(name)) return Arr.fromNullishOr(this.#project.symbolAt(name));
    const elements: ReadonlyArray<ts.ArrayBindingElement> = name.elements;
    return elements.filter(ts.isBindingElement).flatMap((element) => this.#bindings(element.name));
  }

  #holdsContainer(initializer: ts.Expression | undefined): boolean {
    if (initializer === undefined) return false;
    const value = unwrap(initializer);
    if (ts.isArrayLiteralExpression(value) || ts.isObjectLiteralExpression(value)) return true;
    return (
      ts.isNewExpression(value) &&
      ts.isIdentifier(value.expression) &&
      MUTABLE_CONSTRUCTORS.has(value.expression.text)
    );
  }

  #mutationTargets(node: ts.Node): ReadonlyArray<ts.Identifier> {
    if (isAssignment(node)) return this.#root(node.left);
    if (
      (ts.isPrefixUnaryExpression(node) || ts.isPostfixUnaryExpression(node)) &&
      STEPS.has(node.operator)
    ) {
      return this.#root(node.operand);
    }
    if (ts.isDeleteExpression(node)) return this.#root(node.expression);
    if (this.#callsMethodIn(node, MUTATORS)) return this.#root(node.expression.expression);
    return [];
  }

  #root(expression: ts.Expression): ReadonlyArray<ts.Identifier> {
    const value = unwrap(expression);
    if (ts.isIdentifier(value)) return [value];
    if (ts.isPropertyAccessExpression(value) || ts.isElementAccessExpression(value)) {
      return this.#root(value.expression);
    }
    if (this.#callsMethodIn(value, ELEMENT_LOOKUPS)) return this.#root(value.expression.expression);
    return [];
  }

  #callsMethodIn(
    node: ts.Node,
    names: ReadonlySet<string>,
  ): node is ts.CallExpression & { readonly expression: ts.PropertyAccessExpression } {
    return (
      ts.isCallExpression(node) &&
      ts.isPropertyAccessExpression(node.expression) &&
      names.has(node.expression.name.text)
    );
  }
}
