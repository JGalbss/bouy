import { Data, Effect, Exit, Queue } from "effect";
import { ActorStopped, MailboxFull, MessageDropped } from "./errors.ts";
import type { Sendable } from "./Sendable.ts";
import type { StreamChannel } from "./Streaming.ts";
import { runTurn, type Origin, type TurnContext } from "./Turn.ts";

export type OverflowPolicy = "backpressure" | "reject" | "drop-oldest";

export interface MailboxOptions {
  readonly capacity?: number;
  readonly overflow?: OverflowPolicy;
}

export const DEFAULT_CAPACITY = 1024;

const abortReason = (cancellation: AbortSignal): Error => {
  const reason: unknown = cancellation.reason;
  if (reason instanceof Error) return reason;
  return new DOMException("The call was cancelled", "AbortError");
};

export class Reply<A> {
  readonly #settlement = Promise.withResolvers<A>();
  readonly #caller: TurnContext | undefined;
  #open = true;
  #detach: (() => void) | undefined;

  constructor(caller: TurnContext | undefined) {
    this.#caller = caller;
  }

  get promise(): Promise<A> {
    return this.#settlement.promise;
  }

  get isOpen(): boolean {
    return this.#open;
  }

  succeed(value: A): void {
    if (!this.#open) return;
    this.#open = false;
    this.#detach?.();
    this.#settlement.resolve(value);
  }

  cancelWith(cancellation: AbortSignal): void {
    if (cancellation.aborted) {
      this.fail(abortReason(cancellation));
      return;
    }
    const onAbort = (): void => this.fail(abortReason(cancellation));
    cancellation.addEventListener("abort", onAbort, { once: true });
    this.#detach = () => cancellation.removeEventListener("abort", onAbort);
  }

  fail(cause: Error): void {
    if (!this.#open) return;
    this.#open = false;
    this.#detach?.();
    if (this.#caller === undefined) {
      this.#settlement.reject(cause);
      return;
    }
    runTurn(this.#caller, () => this.#settlement.reject(cause));
  }
}

interface Message {
  readonly method: string;
  readonly args: ReadonlyArray<Sendable>;
  readonly origin: Origin;
}

export type Envelope = Data.TaggedEnum<{
  Call: Message & { readonly reply: Reply<Sendable> };
  Cast: Message & { readonly delivered: Reply<boolean> };
  Stream: Message & { readonly channel: StreamChannel };
}>;

export const Envelope = Data.taggedEnum<Envelope>();

const delivered = new Reply<boolean>(undefined);
delivered.succeed(true);

export const WAKE: Envelope = Envelope.Cast({
  method: "",
  args: [],
  origin: { chain: Symbol("bouy.wake"), signal: undefined },
  delivered,
});

export const refuse = (envelope: Envelope, cause: Error): void =>
  Envelope.$match(envelope, {
    Call: (call) => call.reply.fail(cause),
    Cast: (cast) => cast.delivered.succeed(false),
    Stream: (stream) => stream.channel.fail(cause),
  });

const accept = (envelope: Envelope): void => {
  if (Envelope.$is("Cast")(envelope)) envelope.delivered.succeed(true);
};

export class Mailbox {
  readonly capacity: number;
  readonly #queue: Queue.Queue<Envelope>;
  readonly #overflow: OverflowPolicy;
  readonly #actor: string;

  constructor(queue: Queue.Queue<Envelope>, options: MailboxOptions, actor: string) {
    this.#queue = queue;
    this.capacity = options.capacity ?? DEFAULT_CAPACITY;
    this.#overflow = options.overflow ?? "backpressure";
    this.#actor = actor;
  }

  static make(options: MailboxOptions, actor: string): Effect.Effect<Mailbox> {
    return Queue.bounded<Envelope>(options.capacity ?? DEFAULT_CAPACITY).pipe(
      Effect.map((queue) => new Mailbox(queue, options, actor)),
    );
  }

  get size(): number {
    return Queue.sizeUnsafe(this.#queue);
  }

  get take(): Effect.Effect<Envelope> {
    return Queue.take(this.#queue);
  }

  wake(): void {
    Queue.offerUnsafe(this.#queue, WAKE);
  }

  admit(envelope: Envelope): void {
    if (Queue.offerUnsafe(this.#queue, envelope)) {
      accept(envelope);
      return;
    }
    switch (this.#overflow) {
      case "reject":
        refuse(envelope, new MailboxFull({ actor: this.#actor }));
        return;
      case "drop-oldest":
        this.#evictOldestFor(envelope);
        return;
      case "backpressure":
        Effect.runFork(this.#waitForRoom(envelope));
        return;
    }
  }

  close(cause: Error): Effect.Effect<void> {
    return Queue.clear(this.#queue).pipe(
      Effect.flatMap((pending) =>
        Effect.sync(() => {
          for (const envelope of pending) refuse(envelope, cause);
        }),
      ),
      Effect.andThen(Queue.shutdown(this.#queue)),
      Effect.asVoid,
    );
  }

  #evictOldestFor(envelope: Envelope): void {
    const oldest = Queue.takeUnsafe(this.#queue);
    if (oldest !== undefined && Exit.isSuccess(oldest)) {
      refuse(oldest.value, new MessageDropped({ actor: this.#actor }));
    }
    if (Queue.offerUnsafe(this.#queue, envelope)) {
      accept(envelope);
      return;
    }
    refuse(envelope, new MailboxFull({ actor: this.#actor }));
  }

  #waitForRoom(envelope: Envelope): Effect.Effect<void> {
    return Queue.offer(this.#queue, envelope).pipe(
      Effect.map((admitted) => {
        if (admitted) {
          accept(envelope);
          return;
        }
        refuse(envelope, new ActorStopped({ actor: this.#actor }));
      }),
    );
  }
}
