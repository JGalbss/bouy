// Data.TaggedError classes with fields: yield* new MyError({...}) fails the Effect, and
// catchTag finds the error by its _tag.
import { Data, Effect } from "effect";

class InsufficientFunds extends Data.TaggedError("InsufficientFunds")<{
  readonly balance: number;
  readonly requested: number;
}> {}

class AccountLocked extends Data.TaggedError("AccountLocked")<{ readonly message: string }> {}

class ConfigError extends Data.Error<{ readonly key: string }> {}

const withdraw = (balance: number, amount: number, locked: boolean) =>
  Effect.gen(function* () {
    if (locked) {
      yield* new AccountLocked({ message: "the account is locked" });
    }
    if (amount > balance) {
      return yield* new InsufficientFunds({ balance, requested: amount });
    }
    return balance - amount;
  });

console.log(Effect.runSync(withdraw(100, 30, false)));

const short = Effect.runSync(Effect.result(withdraw(10, 30, false)));
if (short._tag === "Failure" && short.failure._tag === "InsufficientFunds") {
  const error = short.failure;
  console.log(error._tag, error.balance, error.requested);
  console.log(
    error instanceof InsufficientFunds,
    error instanceof Error,
    error instanceof AccountLocked,
  );
  console.log(JSON.stringify(error.name), JSON.stringify(error.message));
}

const locked = Effect.runSync(Effect.result(withdraw(10, 1, true)));
if (locked._tag === "Failure") {
  console.log(locked.failure._tag, locked.failure.message, String(locked.failure));
}

const recovered = withdraw(5, 50, false).pipe(
  Effect.catchTag("InsufficientFunds", (error) =>
    Effect.succeed(`short by ${error.requested - error.balance}`),
  ),
);
console.log(Effect.runSync(recovered));

const config = Effect.runSync(Effect.result(Effect.fail(new ConfigError({ key: "PORT" }))));
if (config._tag === "Failure") {
  console.log(config.failure.key, config.failure instanceof ConfigError, "_tag" in config.failure);
}

const direct = Effect.runSync(Effect.result(new AccountLocked({ message: "used as an Effect" })));
console.log(direct._tag, direct._tag === "Failure" ? direct.failure.message : "");

try {
  Effect.runSync(withdraw(1, 2, false));
} catch (error) {
  console.log("runSync throws the error itself:", (error as InsufficientFunds)._tag);
}
