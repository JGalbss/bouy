// From the README of @cfworker/json-schema: validate data against a JSON Schema without code
// generation.
import { Validator } from "@cfworker/json-schema";

const validator = new Validator({
  type: "object",
  properties: { name: { type: "string" }, age: { type: "integer", minimum: 0 } },
  required: ["name"],
});
console.log(JSON.stringify(validator.validate({ name: "Ada", age: 36 })));
const failed = validator.validate({ age: -1 });
console.log(
  failed.valid,
  JSON.stringify(failed.errors.map((error) => [error.keyword, error.instanceLocation])),
);
