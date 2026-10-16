import { spawn, type OptionsArgument } from "../index.ts";
import type { ActorClass, Ref, RemoteMethods } from "../runtime/Blueprint.ts";
import { dispatch } from "../runtime/Messaging.ts";
import { actorKey } from "../runtime/Sendable.ts";

export type Pool<T> = RemoteMethods<T> & { readonly members: ReadonlyArray<Ref<T>> };

export const pool = <C extends ActorClass>(
  actorClass: C,
  size: number,
  ...options: OptionsArgument<C>
): Pool<InstanceType<C>> => {
  if (!Number.isInteger(size) || size < 1) {
    throw new RangeError(`A pool needs a positive whole number of members, not ${size}`);
  }
  const members = Array.from({ length: size }, () => spawn(actorClass, ...options));
  const turns = { next: 0 };
  const [first] = members;
  if (first === undefined) throw new RangeError("A pool needs at least one member");
  const router = first[actorKey].blueprint.routerFor((): Ref<InstanceType<C>> => {
    turns.next = (turns.next + 1) % members.length;
    const rotated = [...members.slice(turns.next), ...members.slice(0, turns.next)];
    return rotated.reduce((best, member) => {
      if (member[actorKey].load < best[actorKey].load) return member;
      return best;
    });
  }, dispatch);
  return Object.freeze({ ...router, members });
};
