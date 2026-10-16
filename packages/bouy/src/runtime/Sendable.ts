import { inspect } from "node:util";
import { Match, Predicate, Result, Schema, SchemaGetter, type SchemaIssue } from "effect";
import type { Actor } from "./Actor.ts";
import { NotSendable } from "./errors.ts";

export const actorKey: unique symbol = Symbol("bouy.actor");

export class Reference {
  readonly [actorKey]: Actor;

  constructor(actor: Actor) {
    this[actorKey] = actor;
  }
}

export interface SendableRecord {
  readonly [key: string]: Sendable;
}

export type Sendable =
  | string
  | number
  | boolean
  | bigint
  | null
  | undefined
  | Date
  | Uint8Array
  | Reference
  | ReadonlyArray<Sendable>
  | ReadonlyMap<Sendable, Sendable>
  | ReadonlySet<Sendable>
  | SendableRecord;

const element = Schema.suspend((): Schema.Codec<Sendable, unknown> => SendableValue);

const cloneOnDecode = <A extends Date | Uint8Array>(
  schema: Schema.Codec<A>,
  clone: (value: A) => A,
): Schema.Codec<A> =>
  schema.pipe(
    Schema.decodeTo(schema, {
      decode: SchemaGetter.transform(clone),
      encode: SchemaGetter.transform(clone),
    }),
  );

const PlainRecord: Schema.Codec<SendableRecord, object> = Schema.declare(
  (input): input is object => {
    if (Object(input) !== input || Array.isArray(input)) return false;
    const prototype = Object.getPrototypeOf(input);
    return prototype === Object.prototype || prototype === null;
  },
).pipe(Schema.decodeTo(Schema.Record(Schema.String, element)));

export const SendableValue: Schema.Codec<Sendable, unknown> = Schema.Union([
  Schema.String,
  Schema.Number,
  Schema.Boolean,
  Schema.BigInt,
  Schema.Null,
  Schema.Undefined,
  cloneOnDecode(Schema.Date, (date) => new Date(date.getTime())),
  cloneOnDecode(Schema.Uint8Array, (bytes) => bytes.slice()),
  Schema.instanceOf(Reference),
  Schema.Array(element),
  Schema.ReadonlyMap(element, element),
  Schema.ReadonlySet(element),
  PlainRecord,
]);

const decodeArguments = Schema.decodeUnknownResult(Schema.Array(SendableValue));
const decodeValue = Schema.decodeUnknownResult(SendableValue);

type Unchecked = ReadonlyArray<unknown> | Sendable;

class Rejection {
  readonly #path: ReadonlyArray<PropertyKey>;
  readonly #root: Unchecked;

  constructor(issue: SchemaIssue.Issue, root: Unchecked) {
    this.#path = Rejection.#pathTo(issue);
    this.#root = root;
  }

  static #pathTo(issue: SchemaIssue.Issue): ReadonlyArray<PropertyKey> {
    const longest = (issues: ReadonlyArray<SchemaIssue.Issue>): ReadonlyArray<PropertyKey> =>
      issues
        .map((nested) => Rejection.#pathTo(nested))
        .toSorted((first, second) => second.length - first.length)[0] ?? [];
    return Match.valueTags(issue, {
      Pointer: (pointer) => [...pointer.path, ...Rejection.#pathTo(pointer.issue)],
      Composite: (composite) => longest(composite.issues),
      AnyOf: (anyOf) => longest(anyOf.issues),
      Filter: (filter) => Rejection.#pathTo(filter.issue),
      Encoding: (encoding) => Rejection.#pathTo(encoding.issue),
      MissingKey: () => [],
      UnexpectedKey: () => [],
      InvalidType: () => [],
      InvalidValue: () => [],
      Forbidden: () => [],
      OneOf: () => [],
    });
  }

  get label(): string {
    const value = this.#path.reduce<unknown>((current, key) => Object(current)[key], this.#root);
    const kind = Match.value(value).pipe(
      Match.when(Predicate.isFunction, () => "a function"),
      Match.when(Predicate.isSymbol, () => "a symbol"),
      Match.when(Predicate.isPromise, () => "a promise"),
      Match.when(
        Predicate.isObject,
        (instance) =>
          `an instance of ${Object.getPrototypeOf(instance)?.constructor?.name ?? "an unnamed class"}`,
      ),
      Match.orElse((other) => inspect(other)),
    );
    const where = this.#path.map((key) => `[${String(key)}]`).join("") || "the top level";
    return `${kind} at ${where}`;
  }
}

const sendableOrFailure = <A>(
  root: Unchecked,
  decode: (input: Unchecked) => Result.Result<A, Schema.SchemaError>,
): A => {
  try {
    const decoded = decode(root);
    if (Result.isSuccess(decoded)) return decoded.success;
    throw new NotSendable({ value: new Rejection(decoded.failure.issue, root).label });
  } catch (cause) {
    if (cause instanceof RangeError)
      throw new NotSendable({ value: "a cyclic or deeply nested value" });
    throw cause;
  }
};

type Primitive = string | number | boolean | bigint | null | undefined;

const isPrimitive = <V>(value: V): value is V & Primitive =>
  Object(value) !== value && !Predicate.isSymbol(value);

export const copyArguments = (args: ReadonlyArray<unknown>): ReadonlyArray<Sendable> => {
  if (args.every(isPrimitive)) return [...args];
  return sendableOrFailure(args, decodeArguments);
};

export const copyValue = (result: Sendable): Sendable => {
  if (isPrimitive(result)) return result;
  return sendableOrFailure(result, decodeValue);
};

export const copyError = (cause: unknown): Error => {
  if (!(cause instanceof Error)) return new Error(inspect(cause));
  const twin = new Error(cause.message);
  Object.defineProperties(twin, {
    name: { value: cause.name, writable: true, configurable: true },
    stack: { value: cause.stack, writable: true, configurable: true },
  });
  if (cause.cause !== undefined) twin.cause = copyError(cause.cause);
  return twin;
};
