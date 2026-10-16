import { Schema } from "effect";
import { isRefTo, type ActorClass, type Ref } from "../runtime/Blueprint.ts";
import { actorKey, type Reference } from "../runtime/Sendable.ts";

export class NameTaken extends Schema.TaggedError<NameTaken>()("NameTaken", {
  name: Schema.String,
}) {
  override get message(): string {
    return `Another live actor already holds the name ${this.name}`;
  }
}

const names = new Map<string, Reference>();

export const register = (name: string, ref: Reference): void => {
  if (names.has(name)) throw new NameTaken({ name });
  names.set(name, ref);
  void ref[actorKey].exited.then(() => names.get(name) === ref && names.delete(name));
};

export const unregister = (name: string): void => {
  names.delete(name);
};

export const lookup = <C extends ActorClass>(
  name: string,
  actorClass: C,
): Ref<InstanceType<C>> | undefined => {
  const ref = names.get(name);
  if (ref === undefined || !isRefTo(ref, actorClass)) return undefined;
  return ref;
};
