// Schema.decodeUnknownEffect returns an Effect that fails with a SchemaError, which
// catchTag("SchemaError") and yield* see like any typed failure.
import { Data, Effect, Schema } from "effect";

const Order = Schema.Struct({
  id: Schema.Number,
  items: Schema.Array(Schema.Struct({ quantity: Schema.Number, sku: Schema.String })),
});
const decodeOrder = Schema.decodeUnknownEffect(Order);

class EmptyOrder extends Data.TaggedError("EmptyOrder")<{ readonly id: number }> {}

const total = (input: unknown) =>
  Effect.gen(function* () {
    const order = yield* decodeOrder(input);
    if (order.items.length === 0) {
      return yield* new EmptyOrder({ id: order.id });
    }
    let count = 0;
    for (const item of order.items) {
      count += item.quantity;
    }
    return `order ${order.id} has ${count} items`;
  });

const describe = (input: unknown) =>
  total(input).pipe(
    Effect.catchTags({
      SchemaError: (error) =>
        Effect.succeed(`invalid order: ${error.message.split("\n").join(" ")}`),
      EmptyOrder: (error) => Effect.succeed(`order ${error.id} is empty`),
    }),
  );

console.log(
  Effect.runSync(
    describe({
      id: 1,
      items: [
        { quantity: 2, sku: "a" },
        { quantity: 3, sku: "b" },
      ],
    }),
  ),
);
console.log(Effect.runSync(describe({ id: 2, items: [] })));
console.log(Effect.runSync(describe({ id: 3, items: [{ quantity: "two", sku: "a" }] })));
console.log(Effect.runSync(describe({ items: [] })));

const failed = Effect.runSync(Effect.result(decodeOrder("not an order")));
if (failed._tag === "Failure") {
  console.log(failed.failure._tag, failed.failure.message);
}
const decoded = Effect.runSync(decodeOrder({ id: 9, items: [], note: "dropped" }));
console.log(decoded);
