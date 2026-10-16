import { Cause, Effect, Queue, Stream } from "effect";
import type { Sendable } from "./Sendable.ts";

export const STREAM_WINDOW = 16;

type StreamQueue = Queue.Queue<Sendable, Error | Cause.Done>;

export class StreamChannel {
  readonly #queue: StreamQueue;

  constructor(queue: StreamQueue) {
    this.#queue = queue;
  }

  static make(): StreamChannel {
    return new StreamChannel(
      Effect.runSync(Queue.bounded<Sendable, Error | Cause.Done>(STREAM_WINDOW)),
    );
  }

  push(item: Sendable): Effect.Effect<boolean> {
    return Queue.offer(this.#queue, item);
  }

  end(): void {
    Queue.endUnsafe(this.#queue);
  }

  fail(cause: Error): void {
    Queue.failCauseUnsafe(this.#queue, Cause.fail(cause));
  }

  consume(start: () => void): AsyncIterable<Sendable> {
    const queue = this.#queue;
    return {
      [Symbol.asyncIterator]: (): AsyncIterator<Sendable> => {
        start();
        const items = Stream.toAsyncIterable(Stream.fromQueue(queue))[Symbol.asyncIterator]();
        return {
          next: () => items.next(),
          return: async (value?: Sendable): Promise<IteratorResult<Sendable>> => {
            Queue.shutdownUnsafe(queue);
            await items.return?.(value);
            return { done: true, value };
          },
        };
      },
    };
  }
}
