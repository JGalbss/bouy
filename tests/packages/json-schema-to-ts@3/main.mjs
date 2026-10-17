// From the README of json-schema-to-ts: the runtime helpers that wrap a validator as a type
// guard. The rest of the package is types.
import { wrapCompilerAsTypeGuard, wrapValidatorAsTypeGuard } from "json-schema-to-ts";

const isPositive = wrapValidatorAsTypeGuard(
  (schema, data) => typeof data === "number" && data > schema.minimum,
);
console.log(isPositive({ minimum: 0 }, 3), isPositive({ minimum: 0 }, -3));
const compile = wrapCompilerAsTypeGuard((schema) => (data) => typeof data === schema.type);
const isString = compile({ type: "string" });
console.log(isString("text"), isString(1));
