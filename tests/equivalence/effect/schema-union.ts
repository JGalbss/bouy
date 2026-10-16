// Schema.Union picks its candidates as Effect does, and Schema.is tests a value.
import { Schema } from "effect";

const message = (schema: Schema.Schema<unknown>, input: unknown) => {
  try {
    return `decoded ${JSON.stringify(Schema.decodeUnknownSync(schema)(input))}`;
  } catch (error) {
    return (error as Error).message;
  }
};

const Id = Schema.Union([Schema.String, Schema.Number]);
console.log(message(Id, "abc"));
console.log(message(Id, 7));
console.log(message(Id, true));

const Mode = Schema.Union([Schema.Literal("read"), Schema.Literal("write")]);
console.log(message(Mode, "write"));
console.log(message(Mode, "delete"));

const Shape = Schema.Union([
  Schema.Struct({ kind: Schema.Literal("circle"), radius: Schema.Number }),
  Schema.Struct({ kind: Schema.Literal("square"), side: Schema.Number }),
]);
console.log(message(Shape, { kind: "circle", radius: 2 }));
console.log(message(Shape, { kind: "square", side: 3, color: "red" }));
console.log(message(Shape, { kind: "square" }));
console.log(message(Shape, { kind: "triangle" }));
console.log(message(Shape, { radius: 1 }));
console.log(message(Shape, "circle"));

const Loose = Schema.Union([
  Schema.Struct({ a: Schema.Number }),
  Schema.Struct({ b: Schema.Number }),
]);
console.log(message(Loose, { b: 1 }));
console.log(message(Loose, { c: 1 }));

const Mixed = Schema.Union([Schema.Literal("none"), Schema.Number]);
console.log(message(Mixed, "none"));
console.log(message(Mixed, "some"));
console.log(message(Schema.Array(Id), [1, "two", null]));

const isShape = Schema.is(Shape);
console.log(isShape({ kind: "circle", radius: 1 }), isShape({ kind: "circle" }), isShape(null));
console.log(Schema.is(Schema.String)("text"), Schema.is(Schema.Number)("text"));
console.log(Schema.is(Schema.Array(Schema.Boolean))([true, false]), Schema.is(Mode)("read"));
