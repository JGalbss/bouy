import { Match } from "effect";
import type { Arguments, MethodName, Ref } from "../runtime/Blueprint.ts";
import { dispatch } from "../runtime/Messaging.ts";
import { actorKey } from "../runtime/Sendable.ts";
import { currentTurn } from "../runtime/Turn.ts";

export type Timing = { readonly every: number } | { readonly after: number };

export const schedule = <T, K extends MethodName<T>>(
  ref: Ref<T>,
  timing: Timing,
  method: K,
  ...args: Arguments<T[K]>
): Disposable => {
  const deliver = (): void => void dispatch.cast(ref, method, args);
  const cancel = Match.value(timing).pipe(
    Match.when({ every: Match.number }, ({ every }) => {
      const timer = setInterval(deliver, every);
      return () => clearInterval(timer);
    }),
    Match.orElse(({ after }) => {
      const timer = setTimeout(deliver, after);
      return () => clearTimeout(timer);
    }),
  );
  void ref[actorKey].exited.then(cancel);
  currentTurn()?.incarnation.signal.addEventListener("abort", cancel, { once: true });
  return { [Symbol.dispose]: cancel };
};
