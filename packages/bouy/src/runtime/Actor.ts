import { Deferred, Effect, type Scope } from "effect";
import type { Behavior, Blueprint, Outcome } from "./Blueprint.ts";
import type { Body } from "./Body.ts";
import { ActorFailed, ActorStopped, CallCycle, Crash, NotSendable } from "./errors.ts";
import { Envelope, refuse, type Mailbox } from "./Mailbox.ts";
import { copyArguments, copyError, copyValue, type Reference, type Sendable } from "./Sendable.ts";
import type { StreamChannel } from "./Streaming.ts";
import { runTurn, TurnContext } from "./Turn.ts";

export type ActorStatus = "starting" | "idle" | "busy" | "restarting" | "stopped" | "failed";

export type ActorExit =
  | { readonly kind: "stopped" }
  | { readonly kind: "failed"; readonly cause: Error };

export interface ActorSnapshot {
  readonly id: string;
  readonly name: string;
  readonly status: ActorStatus;
  readonly mailbox: { readonly size: number; readonly capacity: number };
  readonly processed: number;
  readonly restarts: number;
  readonly lastFailure: string | undefined;
}

export type Embody = (
  args: ReadonlyArray<Sendable>,
  incarnation: Incarnation,
) => Body | Promise<Body>;

export interface ActorSpec {
  readonly id: string;
  readonly name: string;
  readonly blueprint: Blueprint;
  readonly embody: Embody;
  readonly args: ReadonlyArray<Sendable>;
  readonly mailbox: Mailbox;
}

type Settled = Sendable | AsyncIterable<Sendable>;

const DISPOSE_GRACE_MS = 5_000;

const STATUS_BY_EXIT = { stopped: "stopped", failed: "failed" } as const;

const constructorCrash = (cause: unknown): Crash => new Crash({ site: "the constructor", cause });

const isAsyncIterable = (value: Outcome): value is AsyncIterable<Sendable> =>
  Object(value) === value && Symbol.asyncIterator in Object(value);

export class Incarnation {
  readonly generation: number;
  readonly scope: Scope.Scope;
  readonly fault = Deferred.makeUnsafe<never, Crash>();
  readonly #blueprint: Blueprint;
  readonly #controller = new AbortController();
  #body: Body | undefined;
  #faultCause: Error | undefined;

  constructor(generation: number, scope: Scope.Scope, blueprint: Blueprint) {
    this.generation = generation;
    this.scope = scope;
    this.#blueprint = blueprint;
  }

  get signal(): AbortSignal {
    return this.#controller.signal;
  }

  bind(body: Body): void {
    this.#body = body;
  }

  owns(behavior: Behavior): boolean {
    if (this.#body === undefined) return behavior instanceof this.#blueprint.actorClass;
    return this.#body.owns(behavior);
  }

  invoke(method: string, args: ReadonlyArray<Sendable>): Outcome {
    if (this.#body === undefined) throw new TypeError(`${this.#blueprint.name} has not started`);
    return this.#body.invoke(method, args);
  }

  get faultCause(): Error | undefined {
    return this.#faultCause;
  }

  crash(cause: unknown): void {
    this.#faultCause ??= copyError(cause);
    Deferred.doneUnsafe(this.fault, Effect.fail(new Crash({ site: "an async callback", cause })));
  }

  retire(): Effect.Effect<void> {
    this.#controller.abort(new DOMException("The actor stopped", "AbortError"));
    const body = this.#body;
    if (body === undefined) return Effect.void;
    return Effect.tryPromise(() => body.dispose()).pipe(
      Effect.timeout(DISPOSE_GRACE_MS),
      Effect.ignore,
    );
  }
}

type Call = Extract<Envelope, { readonly _tag: "Call" }>;
type Cast = Extract<Envelope, { readonly _tag: "Cast" }>;
type Stream = Extract<Envelope, { readonly _tag: "Stream" }>;

export class Actor {
  readonly id: string;
  readonly name: string;
  readonly label: string;
  readonly blueprint: Blueprint;
  readonly mailbox: Mailbox;
  readonly ref: Reference;
  readonly started = Deferred.makeUnsafe<void, Crash>();
  readonly #embody: Embody;
  readonly #args: ReadonlyArray<Sendable>;
  readonly #exited = Promise.withResolvers<ActorExit>();
  #status: ActorStatus = "starting";
  #exit: ActorExit | undefined;
  #incarnation: Incarnation | undefined;
  #turn: TurnContext | undefined;
  #generation = 0;
  #processed = 0;
  #restarts = 0;
  #lastFailure: string | undefined;

  constructor(spec: ActorSpec) {
    this.id = spec.id;
    this.name = spec.name;
    this.label = `${spec.name}#${spec.id}`;
    this.blueprint = spec.blueprint;
    this.mailbox = spec.mailbox;
    this.#embody = spec.embody;
    this.#args = spec.args;
    this.ref = spec.blueprint.refFor(this);
  }

  get exited(): Promise<ActorExit> {
    return this.#exited.promise;
  }

  get incarnation(): Incarnation | undefined {
    return this.#incarnation;
  }

  get hasStarted(): boolean {
    return this.#generation > 0 && this.#incarnation !== undefined;
  }

  get load(): number {
    return this.mailbox.size + Number(this.#turn !== undefined);
  }

  deliver(envelope: Envelope): void {
    if (this.#exit !== undefined) {
      refuse(envelope, this.#stoppedError());
      return;
    }
    if (!Envelope.$is("Cast")(envelope) && envelope.origin.chain === this.#turn?.origin.chain) {
      refuse(envelope, new CallCycle({ actor: this.label }));
      return;
    }
    this.mailbox.admit(envelope);
  }

  incarnate(): Effect.Effect<never, Crash> {
    return Effect.scoped(
      Effect.gen({ self: this }, function* () {
        const scope = yield* Effect.scope;
        const incarnation = yield* this.#begin(scope);
        yield* Effect.addFinalizer(() => incarnation.retire());
        return yield* Effect.raceFirst(this.#serve(incarnation), Deferred.await(incarnation.fault));
      }),
    ).pipe(Effect.tapError((crash) => Deferred.fail(this.started, crash)));
  }

  restarting(crash: Crash): void {
    this.#status = "restarting";
    this.#restarts += 1;
    this.#lastFailure = String(crash.cause);
  }

  terminate(exit: ActorExit): Effect.Effect<void> {
    return Effect.suspend(() => {
      if (this.#exit !== undefined) return Effect.void;
      this.#exit = exit;
      this.#status = STATUS_BY_EXIT[exit.kind];
      this.#exited.resolve(exit);
      return this.mailbox.close(this.#stoppedError());
    });
  }

  snapshot(): ActorSnapshot {
    return {
      id: this.id,
      name: this.name,
      status: this.#status,
      mailbox: { size: this.mailbox.size, capacity: this.mailbox.capacity },
      processed: this.#processed,
      restarts: this.#restarts,
      lastFailure: this.#lastFailure,
    };
  }

  #stoppedError(): ActorStopped {
    if (this.#exit?.kind === "failed")
      return new ActorStopped({ actor: this.label, cause: this.#exit.cause });
    return new ActorStopped({ actor: this.label });
  }

  #begin(scope: Scope.Scope): Effect.Effect<Incarnation, Crash> {
    const incarnation = new Incarnation(this.#generation + 1, scope, this.blueprint);
    const turn = new TurnContext(this, incarnation, {
      chain: Symbol("bouy.start"),
      signal: undefined,
    });
    return Effect.try({
      try: () => {
        this.#incarnation = incarnation;
        return runTurn(turn, () => this.#embody(copyArguments(this.#args), incarnation));
      },
      catch: constructorCrash,
    }).pipe(
      Effect.flatMap((body) => {
        if (body instanceof Promise)
          return Effect.tryPromise({ try: () => body, catch: constructorCrash });
        return Effect.succeed(body);
      }),
      Effect.map((body) => {
        incarnation.bind(body);
        this.#generation = incarnation.generation;
        this.#status = "idle";
        Deferred.doneUnsafe(this.started, Effect.void);
        return incarnation;
      }),
    );
  }

  #serve(incarnation: Incarnation): Effect.Effect<never, Crash> {
    return Effect.forever(
      Effect.flatMap(this.mailbox.take, (envelope) => this.#turnFor(incarnation, envelope)),
    );
  }

  #turnFor(incarnation: Incarnation, envelope: Envelope): Effect.Effect<void, Crash> {
    if (Envelope.$is("Call")(envelope) && !envelope.reply.isOpen) return Effect.void;
    const turn = new TurnContext(this, incarnation, envelope.origin);
    this.#turn = turn;
    this.#status = "busy";
    const work = Envelope.$match(envelope, {
      Call: (call) => this.#call(turn, call),
      Cast: (cast) => this.#cast(turn, cast),
      Stream: (stream) => this.#stream(turn, stream),
    });
    return work.pipe(
      Effect.onInterrupt(() =>
        Effect.sync(() => refuse(envelope, this.#interruptedError(incarnation, envelope))),
      ),
      Effect.ensuring(Effect.sync(() => this.#endTurn(turn))),
    );
  }

  #interruptedError(incarnation: Incarnation, envelope: Envelope): Error {
    const cause = incarnation.faultCause;
    if (cause === undefined) return new ActorStopped({ actor: this.label });
    return new ActorFailed({ actor: this.label, method: envelope.method, cause });
  }

  #endTurn(turn: TurnContext): void {
    if (this.#turn !== turn) return;
    this.#turn = undefined;
    this.#processed += 1;
    if (this.#status === "busy") this.#status = "idle";
  }

  #invoke(turn: TurnContext, message: Envelope): Effect.Effect<Settled, Crash> {
    return Effect.try({
      try: () => runTurn(turn, () => turn.incarnation.invoke(message.method, message.args)),
      catch: (cause) => new Crash({ site: message.method, cause }),
    }).pipe(
      Effect.flatMap((outcome): Effect.Effect<Settled, Crash> => {
        if (!(outcome instanceof Promise)) return Effect.succeed(outcome);
        return Effect.tryPromise({
          try: (): Promise<Sendable> => outcome,
          catch: (cause) => new Crash({ site: message.method, cause }),
        });
      }),
    );
  }

  #call(turn: TurnContext, call: Call): Effect.Effect<void, Crash> {
    return this.#invoke(turn, call).pipe(
      Effect.flatMap((value) =>
        Effect.try({
          try: () => this.#reply(value, call.method),
          catch: (cause) => copyError(cause),
        }).pipe(
          Effect.match({
            onSuccess: (reply) => call.reply.succeed(reply),
            onFailure: (error) => call.reply.fail(error),
          }),
        ),
      ),
      Effect.catch((crash) => this.#failTurn(turn, call, crash)),
    );
  }

  #reply(value: Settled, method: string): Sendable {
    if (isAsyncIterable(value)) {
      throw new NotSendable({
        value: `the async iterable from ${method}; declare it as async *${method}() to stream`,
      });
    }
    return copyValue(value);
  }

  #cast(turn: TurnContext, cast: Cast): Effect.Effect<void, Crash> {
    return this.#invoke(turn, cast).pipe(
      Effect.asVoid,
      Effect.catch((crash) => this.#failTurn(turn, cast, crash)),
    );
  }

  #stream(turn: TurnContext, stream: Stream): Effect.Effect<void, Crash> {
    return this.#invoke(turn, stream).pipe(
      Effect.flatMap((outcome) => {
        if (isAsyncIterable(outcome)) return this.#pump(turn, outcome, stream.channel);
        const cause = new TypeError(`${stream.method} did not return an async iterable`);
        return Effect.fail(new Crash({ site: stream.method, cause }));
      }),
      Effect.tap(() => Effect.sync(() => stream.channel.end())),
      Effect.catch((crash) => this.#failTurn(turn, stream, crash)),
    );
  }

  #pump(
    turn: TurnContext,
    iterable: AsyncIterable<Sendable>,
    channel: StreamChannel,
  ): Effect.Effect<void, Crash> {
    return Effect.gen(function* () {
      const iterator = runTurn(turn, () => iterable[Symbol.asyncIterator]());
      while (true) {
        const step = yield* Effect.tryPromise({
          try: () => runTurn(turn, () => iterator.next()),
          catch: (cause) => new Crash({ site: "a stream", cause }),
        });
        if (step.done === true) return;
        const item = yield* Effect.try({
          try: () => copyValue(step.value),
          catch: (cause) => new Crash({ site: "a stream", cause }),
        });
        if (!(yield* channel.push(item))) {
          yield* Effect.promise(async () => runTurn(turn, () => iterator.return?.()));
          return;
        }
      }
    });
  }

  #failTurn(turn: TurnContext, message: Envelope, crash: Crash): Effect.Effect<void, Crash> {
    if (turn.isCancelled) {
      refuse(message, new ActorStopped({ actor: this.label, cause: copyError(crash.cause) }));
      return Effect.void;
    }
    const cause = copyError(crash.cause);
    refuse(message, new ActorFailed({ actor: this.label, method: message.method, cause }));
    return Effect.fail(crash);
  }
}
