import type { Behavior, Blueprint, Outcome } from "./Blueprint.ts";
import type { Sendable } from "./Sendable.ts";

export interface Body {
  invoke(method: string, args: ReadonlyArray<Sendable>): Outcome;
  owns(candidate: Behavior): boolean;
  dispose(): Promise<void>;
}

export class LocalBody implements Body {
  readonly #behavior: Behavior;
  readonly #blueprint: Blueprint;

  constructor(behavior: Behavior, blueprint: Blueprint) {
    this.#behavior = behavior;
    this.#blueprint = blueprint;
  }

  invoke(method: string, args: ReadonlyArray<Sendable>): Outcome {
    const entry = this.#blueprint.methods.get(method);
    if (entry === undefined) throw new TypeError(`${this.#blueprint.name} has no method ${method}`);
    return entry.invoke.call(this.#behavior, ...args);
  }

  owns(candidate: Behavior): boolean {
    return candidate === this.#behavior;
  }

  async dispose(): Promise<void> {
    await this.#blueprint.disposer?.call(this.#behavior);
  }
}
