import { Array as Arr, Option } from "effect";
import ts from "typescript";
import { isObjectType, type Project } from "./Project.ts";

const DEPTH_LIMIT = 24;

const PRIMITIVES =
  ts.TypeFlags.StringLike |
  ts.TypeFlags.NumberLike |
  ts.TypeFlags.BigIntLike |
  ts.TypeFlags.BooleanLike |
  ts.TypeFlags.EnumLike |
  ts.TypeFlags.Null |
  ts.TypeFlags.Undefined |
  ts.TypeFlags.Void |
  ts.TypeFlags.Never;

const OPAQUE: ReadonlyArray<readonly [ts.TypeFlags, string]> = [
  [ts.TypeFlags.Any, "any"],
  [ts.TypeFlags.Unknown, "unknown"],
  [ts.TypeFlags.NonPrimitive, "object"],
];

const ALWAYS_SENDABLE: ReadonlyArray<string> = ["Date", "Uint8Array"];

const REFUSED_GLOBALS: ReadonlyArray<readonly [string, string]> = [
  ["Error", "an Error"],
  ["WeakMap", "a WeakMap"],
  ["WeakSet", "a WeakSet"],
  ["WeakRef", "a WeakRef"],
];

const CONTAINERS: ReadonlyArray<readonly [string, ReadonlyArray<string>]> = [
  ["Array", ["[number]"]],
  ["ReadonlyArray", ["[number]"]],
  ["Map", ["<key>", "<value>"]],
  ["ReadonlyMap", ["<key>", "<value>"]],
  ["Set", ["<element>"]],
  ["ReadonlySet", ["<element>"]],
];

type Segment =
  | { readonly kind: "property"; readonly name: string }
  | { readonly kind: "element"; readonly label: string };

export interface Refusal {
  readonly kind: "refused" | "unverifiable";
  readonly explanation: string;
}

interface Problem {
  readonly kind: Refusal["kind"];
  readonly path: ReadonlyArray<Segment>;
  readonly reason: string;
}

interface Ancestor {
  readonly type: ts.Type;
  readonly symbol: ts.Symbol;
}

interface Container {
  readonly type: ts.Type;
  readonly labels: ReadonlyArray<string>;
}

class Walk {
  readonly path: ReadonlyArray<Segment>;
  readonly #seen: Set<ts.Type>;

  constructor(path: ReadonlyArray<Segment>, seen: Set<ts.Type>) {
    this.path = path;
    this.#seen = seen;
  }

  isTooDeep(): boolean {
    return this.path.length > DEPTH_LIMIT;
  }

  enter(type: ts.Type): boolean {
    if (this.#seen.has(type)) return false;
    this.#seen.add(type);
    return true;
  }

  into(segment: Segment): Walk {
    return new Walk([...this.path, segment], this.#seen);
  }

  refuse(reason: string): Option.Option<Problem> {
    return Option.some({ kind: "refused", path: this.path, reason });
  }

  cannotVerify(reason: string): Option.Option<Problem> {
    return Option.some({ kind: "unverifiable", path: this.path, reason });
  }
}

export class Sendable {
  readonly #project: Project;
  readonly #refClasses: ReadonlySet<ts.Symbol>;
  readonly #alwaysSendable: ReadonlySet<ts.Symbol>;
  readonly #refusedGlobals: ReadonlyMap<ts.Symbol, string>;
  readonly #containers: ReadonlyMap<ts.Symbol, ReadonlyArray<string>>;
  readonly #modifierAliases: ReadonlySet<ts.Symbol>;

  constructor(project: Project, refClasses: ReadonlySet<ts.Symbol>) {
    this.#project = project;
    this.#refClasses = refClasses;
    this.#alwaysSendable = new Set(
      ALWAYS_SENDABLE.flatMap((name) => Arr.fromNullishOr(project.global(name))),
    );
    this.#refusedGlobals = new Map(
      REFUSED_GLOBALS.flatMap(([name, reason]) => this.#global(name, reason)),
    );
    this.#containers = new Map(CONTAINERS.flatMap(([name, labels]) => this.#global(name, labels)));
    this.#modifierAliases = new Set(Arr.fromNullishOr(project.global("Readonly")));
  }

  check(type: ts.Type): Option.Option<Refusal> {
    return Option.map(this.#find(type, new Walk([], new Set())), (problem) => ({
      kind: problem.kind,
      explanation: this.#explain(problem),
    }));
  }

  #global<A>(name: string, value: A): ReadonlyArray<readonly [ts.Symbol, A]> {
    return Arr.fromNullishOr(this.#project.global(name)).map((symbol): readonly [ts.Symbol, A] => [
      symbol,
      value,
    ]);
  }

  #find(type: ts.Type, walk: Walk): Option.Option<Problem> {
    const opaque = OPAQUE.find(([flag]) => (type.flags & flag) !== 0);
    if (opaque !== undefined) {
      return walk.cannotVerify(`has the type ${opaque[1]}, which the checker cannot verify`);
    }
    if ((type.flags & ts.TypeFlags.ESSymbolLike) !== 0) return walk.refuse("is a symbol");
    if ((type.flags & PRIMITIVES) !== 0) return Option.none();
    if (walk.isTooDeep()) {
      return walk.cannotVerify(
        `is nested more than ${DEPTH_LIMIT} levels deep, which the checker cannot verify`,
      );
    }
    if (!walk.enter(type)) return Option.none();
    if (type.isUnion()) return this.#first(type.types, walk);
    if (type.isIntersection()) return this.#intersection(type.types, walk);
    if (isObjectType(type)) return this.#object(type, walk);
    return this.#constraint(type, walk);
  }

  #first(types: ReadonlyArray<ts.Type>, walk: Walk): Option.Option<Problem> {
    return Arr.findFirst(types, (member) => this.#find(member, walk));
  }

  #intersection(types: ReadonlyArray<ts.Type>, walk: Walk): Option.Option<Problem> {
    const settled = types.some(
      (member) => (member.flags & PRIMITIVES) !== 0 || this.#isActorRef(member),
    );
    if (settled) return Option.none();
    return this.#first(
      types.filter((member) => !this.#isEmptyObject(member)),
      walk,
    );
  }

  #object(type: ts.ObjectType, walk: Walk): Option.Option<Problem> {
    if (this.#isActorRef(type)) return Option.none();
    const source = this.#modifiedSource(type);
    if (Option.isSome(source)) return this.#find(source.value, walk);
    const lineage = this.#lineage(type);
    if (lineage.some((ancestor) => this.#alwaysSendable.has(ancestor.symbol))) return Option.none();
    const refusal = this.#refusalReason(type, lineage);
    if (Option.isSome(refusal)) return walk.refuse(refusal.value);
    const container = this.#container(type, lineage);
    if (Option.isSome(container)) {
      return this.#elements(
        this.#project.typeArguments(container.value.type),
        container.value.labels.map((label) => ({ kind: "element", label })),
        walk,
      );
    }
    if (this.#isEmptyObject(type)) {
      const name = this.#project.checker.typeToString(type);
      return walk.cannotVerify(`has the type ${name}, which the checker cannot verify`);
    }
    return this.#members(type, walk);
  }

  #modifiedSource(type: ts.Type): Option.Option<ts.Type> {
    const alias = type.aliasSymbol;
    if (alias === undefined || !this.#modifierAliases.has(alias)) return Option.none();
    return Arr.head(type.aliasTypeArguments ?? []);
  }

  #refusalReason(type: ts.Type, lineage: ReadonlyArray<Ancestor>): Option.Option<string> {
    if (type.getCallSignatures().length > 0) return Option.some("is a function");
    if (type.getConstructSignatures().length > 0) return Option.some("is a class constructor");
    if (this.#project.isThenable(type)) return Option.some("is a promise");
    if (this.#project.isAsyncIterable(type)) return Option.some("is an async iterable");
    const refused = Arr.findFirst(lineage, (ancestor) =>
      Option.fromUndefinedOr(this.#refusedGlobals.get(ancestor.symbol)),
    );
    if (Option.isSome(refused)) return Option.some(`is ${refused.value}`);
    const own = Arr.head(lineage);
    if (Option.isNone(own) || (own.value.symbol.flags & ts.SymbolFlags.Class) === 0) {
      return Option.none();
    }
    return Option.some(`is an instance of the class ${this.#project.checker.typeToString(type)}`);
  }

  #container(type: ts.Type, lineage: ReadonlyArray<Ancestor>): Option.Option<Container> {
    if (this.#project.checker.isTupleType(type)) {
      const labels = this.#project.typeArguments(type).map((_, index) => `[${index}]`);
      return Option.some({ type, labels });
    }
    return Arr.findFirst(lineage, (ancestor) =>
      Option.map(Option.fromUndefinedOr(this.#containers.get(ancestor.symbol)), (labels) => ({
        type: ancestor.type,
        labels,
      })),
    );
  }

  #isEmptyObject(type: ts.Type): boolean {
    const checker = this.#project.checker;
    return (
      isObjectType(type) &&
      checker.getPropertiesOfType(type).length === 0 &&
      checker.getIndexInfosOfType(type).length === 0 &&
      type.getCallSignatures().length === 0 &&
      type.getConstructSignatures().length === 0
    );
  }

  #members(type: ts.Type, walk: Walk): Option.Option<Problem> {
    const checker = this.#project.checker;
    const properties = checker.getPropertiesOfType(type);
    const indexes = checker.getIndexInfosOfType(type);
    return this.#elements(
      [
        ...properties.map((property) => checker.getTypeOfSymbol(property)),
        ...indexes.map((index) => index.type),
      ],
      [
        ...properties.map((property): Segment => ({
          kind: "property",
          name: checker.symbolToString(property),
        })),
        ...indexes.map((index): Segment => ({
          kind: "element",
          label: `[${checker.typeToString(index.keyType)}]`,
        })),
      ],
      walk,
    );
  }

  #elements(
    types: ReadonlyArray<ts.Type>,
    segments: ReadonlyArray<Segment>,
    walk: Walk,
  ): Option.Option<Problem> {
    return Arr.findFirst(Arr.zip(types, segments), ([element, segment]) =>
      this.#find(element, walk.into(segment)),
    );
  }

  #constraint(type: ts.Type, walk: Walk): Option.Option<Problem> {
    const checker = this.#project.checker;
    const constraint = checker.getBaseConstraintOfType(type);
    if (constraint === undefined) {
      return walk.cannotVerify(
        `has the type ${checker.typeToString(type)}, which has no constraint, so the checker cannot verify it`,
      );
    }
    return this.#find(constraint, walk);
  }

  #lineage(type: ts.Type): ReadonlyArray<Ancestor> {
    const symbol = type.getSymbol();
    if (symbol === undefined) return [];
    const bases = this.#project.checker.getDeclaredTypeOfSymbol(symbol).getBaseTypes() ?? [];
    return [{ type, symbol }, ...bases.flatMap((base) => this.#lineage(base))];
  }

  #isActorRef(type: ts.Type): boolean {
    const symbol = type.getSymbol();
    return symbol !== undefined && this.#refClasses.has(symbol);
  }

  #explain(problem: Problem): string {
    const accessor = problem.path.map((segment) => this.#render(segment)).join("");
    const first = Arr.head(problem.path);
    if (Option.isNone(first)) return `it ${problem.reason}`;
    if (first.value.kind === "property") {
      return `the property ${accessor.slice(1)} ${problem.reason}`;
    }
    return `the value at ${accessor} ${problem.reason}`;
  }

  #render(segment: Segment): string {
    if (segment.kind === "property") return `.${segment.name}`;
    return segment.label;
  }
}
