// Schema.Struct, String, Number, Boolean, Literal, Array, and optional with
// decodeUnknownSync: the decoded value, or a SchemaError with the message of Effect.
import { Schema } from "effect";

const Person = Schema.Struct({
  age: Schema.Number,
  kind: Schema.Literal("person"),
  name: Schema.String,
  nickname: Schema.optional(Schema.String),
  tags: Schema.Array(Schema.String),
  verified: Schema.Boolean,
});
const decodePerson = Schema.decodeUnknownSync(Person);

const ann = decodePerson({
  age: 31,
  kind: "person",
  name: "Ann",
  tags: ["admin"],
  verified: true,
  extra: "dropped",
});
console.log(ann);
console.log(
  decodePerson({ age: 4, kind: "person", name: "Bo", nickname: "B", tags: [], verified: false }),
);

const attempt = (label: string, input: unknown) => {
  try {
    decodePerson(input);
    console.log(label, "decoded");
  } catch (error) {
    const schemaError = error as { _tag: string; name: string; message: string };
    console.log(`${label}: ${schemaError._tag} ${schemaError.name}`);
    console.log(schemaError.message);
  }
};

attempt("not an object", "Ann");
attempt("an array", []);
attempt("null", null);
attempt("missing key", { age: 1 });
attempt("wrong type", { age: "old", kind: "person", name: "Cy", tags: [], verified: true });
attempt("wrong literal", { age: 1, kind: "robot", name: "Cy", tags: [], verified: true });
attempt("wrong item", { age: 1, kind: "person", name: "Cy", tags: ["ok", 7], verified: true });
attempt("wrong optional", {
  age: 1,
  kind: "person",
  name: "Cy",
  nickname: 5,
  tags: [],
  verified: true,
});

console.log(Schema.decodeUnknownSync(Schema.Number)(1.5));
console.log(Schema.decodeUnknownSync(Schema.Array(Schema.Number))([1, 2, 3]));
console.log(Schema.decodeUnknownSync(Schema.Literal(3))(3));
for (const [schema, input] of [
  [Schema.String, 1],
  [Schema.Number, "1"],
  [Schema.Boolean, "true"],
  [Schema.Literal("on"), "off"],
  [Schema.Literal(1), 2],
  [Schema.Array(Schema.String), "abc"],
] as const) {
  try {
    Schema.decodeUnknownSync(schema as Schema.Schema<unknown>)(input);
  } catch (error) {
    console.log((error as Error).message);
  }
}
