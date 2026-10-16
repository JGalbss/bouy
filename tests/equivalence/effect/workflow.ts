// A small service built from the Effect subset: validated input, typed errors, retries,
// concurrency, and a timeout, composed with generators and pipe.
import { Console, Data, Effect, Schedule, Schema } from "effect";

class OutOfStock extends Data.TaggedError("OutOfStock")<{ readonly sku: string }> {}
class PaymentDeclined extends Data.TaggedError("PaymentDeclined")<{ readonly amount: number }> {}

const OrderInput = Schema.Struct({
  customer: Schema.String,
  lines: Schema.Array(
    Schema.Struct({ price: Schema.Number, quantity: Schema.Number, sku: Schema.String }),
  ),
});

const stock: Record<string, number> = { apple: 5, pear: 0, plum: 9 };

const reserve = Effect.fn("reserve")(function* (sku: string, quantity: number) {
  yield* Effect.sleep(20);
  const available = stock[sku] ?? 0;
  if (available < quantity) {
    return yield* new OutOfStock({ sku });
  }
  return `${quantity} x ${sku}`;
});

const charge = (amount: number) =>
  Effect.gen(function* () {
    yield* Console.log(`charging ${amount}`);
    if (amount > 100) {
      return yield* new PaymentDeclined({ amount });
    }
    return `receipt for ${amount}`;
  });

const placeOrder = (input: unknown) =>
  Effect.gen(function* () {
    const order = yield* Schema.decodeUnknownEffect(OrderInput)(input);
    const reserved = yield* Effect.forEach(
      order.lines,
      (line) => reserve(line.sku, line.quantity),
      {
        concurrency: "unbounded",
      },
    );
    let amount = 0;
    for (const line of order.lines) {
      amount += line.price * line.quantity;
    }
    const receipt = yield* charge(amount).pipe(
      Effect.retry(Schedule.recurs(1)),
      Effect.timeout("2 seconds"),
    );
    return { customer: order.customer, receipt, reserved };
  }).pipe(
    Effect.catchTags({
      OutOfStock: (error) => Effect.succeed(`sorry, ${error.sku} is sold out`),
      PaymentDeclined: (error) => Effect.succeed(`payment of ${error.amount} declined`),
      SchemaError: (error) => Effect.succeed(`bad order: ${error.message.split("\n")[0]}`),
    }),
  );

const orders: unknown[] = [
  {
    customer: "ann",
    lines: [
      { price: 2, quantity: 3, sku: "apple" },
      { price: 1, quantity: 4, sku: "plum" },
    ],
  },
  { customer: "bo", lines: [{ price: 3, quantity: 1, sku: "pear" }] },
  { customer: "cy", lines: [{ price: 30, quantity: 4, sku: "plum" }] },
  { customer: 7, lines: [] },
];

for (const order of orders) {
  console.log(await Effect.runPromise(placeOrder(order)));
}

// These two orders print nothing while they run, so their concurrent run prints in order.
const quiet = await Effect.runPromise(
  Effect.all([orders[1], orders[3]].map(placeOrder), { concurrency: 2 }),
);
console.log(quiet);
