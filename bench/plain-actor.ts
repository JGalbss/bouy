type Letter = () => PromiseLike<void> | undefined;

export class PlainActor<Behavior> {
  readonly #behavior: Behavior;
  readonly #mailbox: Array<Letter> = [];
  #scheduled = false;

  constructor(behavior: Behavior) {
    this.#behavior = behavior;
  }

  ask<Reply>(message: (behavior: Behavior) => Reply | PromiseLike<Reply>): Promise<Reply> {
    const { promise, resolve, reject } = Promise.withResolvers<Reply>();
    this.#mailbox.push(() => {
      try {
        const outcome = message(this.#behavior);
        if (outcome instanceof Promise) return outcome.then(resolve, reject);
        resolve(outcome);
      } catch (cause) {
        reject(cause);
      }
      return undefined;
    });
    if (this.#scheduled) return promise;
    this.#scheduled = true;
    queueMicrotask(() => this.#readMailbox());
    return promise;
  }

  #readMailbox(): void {
    for (let letter = this.#mailbox.shift(); letter !== undefined; letter = this.#mailbox.shift()) {
      const pending = letter();
      if (pending !== undefined) {
        void pending.then(() => this.#readMailbox());
        return;
      }
    }
    this.#scheduled = false;
  }
}
