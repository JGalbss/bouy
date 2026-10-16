import { Schema } from "effect";

export class ActorFailed extends Schema.TaggedError<ActorFailed>()("ActorFailed", {
  actor: Schema.String,
  method: Schema.String,
  cause: Schema.Defect(),
}) {
  override get message(): string {
    return `${this.actor} failed in ${this.method}: ${String(this.cause)}`;
  }
}

export class ActorStopped extends Schema.TaggedError<ActorStopped>()("ActorStopped", {
  actor: Schema.String,
  cause: Schema.optional(Schema.Defect()),
}) {
  override get message(): string {
    return `${this.actor} is stopped`;
  }
}

export class MailboxFull extends Schema.TaggedError<MailboxFull>()("MailboxFull", {
  actor: Schema.String,
}) {
  override get message(): string {
    return `${this.actor} has a full mailbox`;
  }
}

export class MessageDropped extends Schema.TaggedError<MessageDropped>()("MessageDropped", {
  actor: Schema.String,
}) {
  override get message(): string {
    return `${this.actor} dropped this message to make room for a newer one`;
  }
}

export class CallCycle extends Schema.TaggedError<CallCycle>()("CallCycle", {
  actor: Schema.String,
}) {
  override get message(): string {
    return `${this.actor} is busy with a call that waits on this call. Use cast() or pass the data in the first call.`;
  }
}

export class NotSendable extends Schema.TaggedError<NotSendable>()("NotSendable", {
  value: Schema.String,
}) {
  override get message(): string {
    return `${this.value} cannot cross an actor boundary. Send plain data or an actor ref.`;
  }
}

export class ActorClassInvalid extends Schema.TaggedError<ActorClassInvalid>()(
  "ActorClassInvalid",
  {
    actorClass: Schema.String,
    reason: Schema.String,
  },
) {
  override get message(): string {
    return `${this.actorClass} cannot be an actor: ${this.reason}`;
  }
}

export class Crash extends Schema.TaggedError<Crash>()("Crash", {
  site: Schema.String,
  cause: Schema.Defect(),
}) {}

export const keepOrWrap = <E extends Error>(
  cause: unknown,
  expected: abstract new (...args: never) => E,
  wrap: () => E,
): E => {
  if (cause instanceof expected) return cause;
  return wrap();
};
