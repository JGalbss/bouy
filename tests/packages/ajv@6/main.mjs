// From the README of ajv: compile a JSON Schema, validate data, and read the errors.
import Ajv from "ajv";

const ajv = new Ajv({ allErrors: true });
const validate = ajv.compile({
  type: "object",
  properties: { name: { type: "string" }, age: { type: "integer", minimum: 0 } },
  required: ["name"],
  additionalProperties: false,
});
console.log(validate({ name: "Ada", age: 36 }));
console.log(validate({ age: -1, extra: true }));
console.log(JSON.stringify(validate.errors.map((error) => [error.keyword, error.message])));
console.log(ajv.errorsText(validate.errors));
