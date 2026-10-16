import {
  Blueprint,
  type ActorClass,
  type Cast,
  type Dispatch,
  type Location,
  type Ref,
} from "./Blueprint.ts";
import { ActorStopped, keepOrWrap, NotSendable } from "./errors.ts";
import { Envelope, Reply } from "./Mailbox.ts";
import { actorKey, copyArguments, copyError, type Sendable } from "./Sendable.ts";
import { StreamChannel } from "./Streaming.ts";
import { currentOrigin, currentTurn } from "./Turn.ts";

const blueprints = new WeakMap<ActorClass, Blueprint>();
const locations = new WeakMap<ActorClass, Location>();

const staleCaller = (): ActorStopped | undefined => {
  const caller = currentTurn();
  if (caller === undefined || caller.actor.incarnation === caller.incarnation) return undefined;
  return new ActorStopped({ actor: caller.actor.label });
};

export const dispatch: Dispatch = {
  call(ref, method, args) {
    const reply = new Reply<Sendable>(currentTurn());
    const stale = staleCaller();
    if (stale !== undefined) {
      reply.fail(stale);
      return reply.promise;
    }
    try {
      const origin = currentOrigin();
      if (origin.signal !== undefined) reply.cancelWith(origin.signal);
      ref[actorKey].deliver(Envelope.Call({ method, args: copyArguments(args), origin, reply }));
    } catch (cause) {
      reply.fail(keepOrWrap(cause, NotSendable, () => copyError(cause)));
    }
    return reply.promise;
  },

  cast(ref, method, args) {
    const delivered = new Reply<boolean>(undefined);
    if (staleCaller() !== undefined) {
      delivered.succeed(false);
      return delivered.promise;
    }
    const origin = { chain: Symbol("bouy.cast"), signal: undefined };
    ref[actorKey].deliver(Envelope.Cast({ method, args: copyArguments(args), origin, delivered }));
    return delivered.promise;
  },

  stream(ref, method, args) {
    const channel = StreamChannel.make();
    const origin = currentOrigin();
    const payload = copyArguments(args);
    const opened = { done: false };
    return channel.consume(() => {
      if (opened.done) return;
      opened.done = true;
      ref[actorKey].deliver(Envelope.Stream({ method, args: payload, origin, channel }));
    });
  },
};

export const blueprintFor = (actorClass: ActorClass): Blueprint => {
  const known = blueprints.get(actorClass);
  if (known !== undefined) return known;
  const blueprint = new Blueprint(actorClass, dispatch);
  const location = locations.get(actorClass);
  if (location !== undefined) blueprint.locate(location);
  blueprints.set(actorClass, blueprint);
  return blueprint;
};

export const locate = (actorClass: ActorClass, location: Location): void => {
  locations.set(actorClass, location);
  blueprints.get(actorClass)?.locate(location);
};

export const castViewFor = <T>(ref: Ref<T>): Cast<T> =>
  ref[actorKey].blueprint.castFor(ref, dispatch);
